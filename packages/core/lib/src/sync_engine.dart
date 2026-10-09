import 'dart:async';
import 'dart:io';

import 'discovery.dart';
import 'item.dart';
import 'node_client.dart';
import 'shelf_store.dart';

class _PeerState {
  _PeerState(this.peer);
  Peer peer;
  Uri? base; // last address that answered
  Timer? poll;
  bool refreshing = false;
  bool again = false;
  int failures = 0;

  /// Since when this peer has answered every poll; null while unreachable.
  DateTime? okSince;

  /// When the current run of failed polls began; null while it answers.
  DateTime? failingSince;

  List<Uri> get candidates => [
    ?base,
    for (final u in peer.baseUris)
      if (u != base) u,
  ];
}

/// Tracks peers, mirrors their items into the store, and copies small items
/// eagerly.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.discovery,
    NodeClient? client,
    this.eagerCopyBytes = defaultEagerCopyBytes,
    this.eagerDeadline = defaultEagerDeadline,
    this.pollInterval = const Duration(seconds: 3),
  }) : client = client ?? NodeClient();

  final ShelfStore store;
  final PeerDiscovery discovery;
  final NodeClient client;
  final int eagerCopyBytes;

  /// Wall-clock time an eager copy gets, plus a second per 256 KB of the
  /// item. One that runs over is dropped and counts as a failed try: a
  /// sender that trickles bytes never trips the stall timeout, and would
  /// otherwise hold its slots for as long as it likes, past the item's
  /// expiry and its own departure. A tap has no deadline.
  final Duration eagerDeadline;
  final Duration pollInterval;

  /// The time an eager copy of [bytes] gets: [eagerDeadline] plus a second
  /// per 256 KB. The app waits no longer than this for an arrival it means
  /// to copy to the clipboard.
  Duration eagerDeadlineFor(int bytes) =>
      eagerDeadline + Duration(milliseconds: bytes * 1000 ~/ (256 << 10));

  /// After this many failed polls in a row, a peer counts as gone.
  static const maxFailures = 3;

  /// Eager copies running at once. A burst of small items would otherwise
  /// open a socket and a `.part` file each, all in the same tick, and run
  /// a phone or a Mac app out of file descriptors (256 by default), failing
  /// most of the copies and this node's own server with them.
  static const maxEagerDownloads = 4;

  /// Eager copies running at once from any one sender, so a slow one (or a
  /// hostile one, trickling bytes) cannot take every slot while another's
  /// one-line text waits behind it.
  static const maxEagerPerPeer = 2;

  /// Eager copies started per item. One that fails is queued again by the
  /// next poll; after this many, the item waits for a tap like a large one.
  static const maxEagerTries = 3;

  final _peers = <String, _PeerState>{};

  /// Every node discovery lists, by id, whatever its mode: [_peers] is the
  /// ones this node syncs with, those whose hint is [hint]. Pairing lists
  /// from the rest too, and private mode reaches them to share a new key.
  final _known = <String, Peer>{};

  /// The circle hint of private mode, or null in public mode. Only peers
  /// advertising the same are synced with: public nodes and private ones
  /// never see each other, nor two circles. Set with [rescan].
  String? _hint;
  String? get hint => _hint;
  final _downloads = <String, Future<String>>{};

  /// Keys of items waiting for an eager copy, oldest first; a set, since
  /// every poll queues whatever is still uncopied.
  final _eagerQueue = <String>{};
  var _eagerRunning = 0;
  final _eagerByPeer = <String, int>{};

  /// Deadlines of running eager copies, by key.
  final _deadlines = <String, Timer>{};

  /// Transfers running now. [stop] waits for each to let go of its files:
  /// one still opening or deleting its `.part` after a stop would write
  /// into a directory its node is about to wipe.
  final _transfers = <Future<void>>{};

  /// Keys of mirror downloads someone asked for ([fetch]) while they run:
  /// a tap that finds an eager copy running joins it, and from then on it
  /// may start over as the tap's own would ([_transfer]).
  final _tapped = <String>{};

  /// Eager copies started per mirror. Kept beside the item, not by key, so
  /// the count goes with it; a mirror that leaves and comes back is a new
  /// item, with a fresh count.
  final _eagerTries = Expando<int>();
  final _peerChanges = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<void>>[];

  /// Fires when the set of reachable peers changes.
  Stream<void> get peerChanges => _peerChanges.stream;

  /// Peers that answered their last poll.
  List<Peer> get reachablePeers => [
    for (final s in _peers.values)
      if (s.base != null && s.failures == 0) s.peer,
  ];

  /// Peers discovery still lists that have missed [maxFailures] polls in a
  /// row: their uncopied items are gone and they are not in
  /// [reachablePeers]. Discovery can keep a device that left without
  /// saying so for a long while, so this alone does not mean it is there.
  List<Peer> get unreachablePeers => [
    for (final s in _peers.values)
      if (s.failures >= maxFailures) s.peer,
  ];

  /// Every node discovery lists, synced with or not.
  List<Peer> get knownPeers => [..._known.values];

  /// Nodes nearby with pairing open, whatever their mode.
  List<Peer> get pairingPeers => [
    for (final p in _known.values)
      if (p.pairing) p,
  ];

  /// Switches to syncing with peers that advertise [hint]: drops those
  /// that no longer match, as if they had left, and takes up the known
  /// ones that now do.
  void rescan(String? hint) {
    _hint = hint;
    for (final id in [..._peers.keys]) {
      if (_known[id]?.hint != hint) _down(id);
    }
    for (final p in [..._known.values]) {
      if (p.hint == hint && !_peers.containsKey(p.id)) _up(p);
    }
    _peerChanges.add(null);
  }

  /// Since when [id] has been continuously reachable; null if it is not.
  DateTime? okSince(String id) => _peers[id]?.okSince;

  /// When [id]'s current run of failed polls began; null if it answers.
  DateTime? failingSince(String id) => _peers[id]?.failingSince;

  /// Name of a peer this node knows, reachable or not; null once it is gone.
  String? peerName(String id) => _peers[id]?.peer.name;

  /// Tests only: backdate a peer's reachability.
  void debugSetOkSince(String id, DateTime t) => _peers[id]?.okSince = t;

  void start() {
    _subs
      ..add(discovery.events.listen(_onEvent))
      ..add(store.localChanges.listen((_) => _nudgeAll()));
  }

  void _onEvent(PeerEvent e) {
    switch (e) {
      case PeerUp(:final peer):
        if (peer.id == store.nodeId) return;
        final was = _known[peer.id];
        _known[peer.id] = peer;
        if (peer.hint != _hint) {
          _down(peer.id);
          // Pairing lists it whatever its mode.
          if (peer.pairing || (was?.pairing ?? false)) _peerChanges.add(null);
          return;
        }
        if (was?.pairing != peer.pairing) _peerChanges.add(null);
        _up(peer);
      case PeerDown(:final id):
        final was = _known.remove(id);
        if (was != null && was.pairing) _peerChanges.add(null);
        _down(id);
    }
  }

  void _up(Peer peer) {
    final s = _peers[peer.id];
    if (s != null) {
      // A private node advertises no name; keep the one its list gave.
      s.peer = peer.name.isEmpty ? peer.named(s.peer.name) : peer;
    } else {
      final s = _peers[peer.id] = _PeerState(peer);
      s.poll = Timer.periodic(pollInterval, (_) => _refresh(s));
    }
    _refresh(_peers[peer.id]!);
  }

  void _down(String id) {
    final s = _peers.remove(id);
    if (s == null) return;
    s.poll?.cancel();
    _dropUncopied(id);
    _peerChanges.add(null);
  }

  /// Handles `POST /v1/changed`.
  void onNudge(String? fromId) {
    final s = _peers[fromId];
    if (s != null) {
      _refresh(s);
    } else {
      _peers.values.forEach(_refresh);
    }
  }

  Future<void> _refresh(_PeerState s) async {
    if (s.refreshing) {
      s.again = true;
      return;
    }
    s.refreshing = true;
    try {
      do {
        s.again = false;
        await _refreshOnce(s);
      } while (s.again && _peers[s.peer.id] == s);
    } finally {
      s.refreshing = false;
    }
  }

  Future<void> _refreshOnce(_PeerState s) async {
    for (final base in s.candidates) {
      try {
        final (:items, :name) = await client.fetchShelf(base, store.nodeId);
        final list = items;
        if (_peers[s.peer.id] != s) return; // went away meanwhile
        if (name != null && name != s.peer.name) {
          s.peer = s.peer.named(name);
          _peerChanges.add(null);
        }
        final changed = s.base != base || s.failures != 0;
        s
          ..base = base
          ..failures = 0
          ..failingSince = null
          ..okSince ??= DateTime.now();
        if (changed) _peerChanges.add(null);
        _reconcile(s, list);
        return;
      } catch (_) {
        // try the next address
      }
    }
    s
      ..failures += 1
      ..okSince = null
      ..failingSince ??= DateTime.now();
    if (s.failures == maxFailures) {
      _dropUncopied(s.peer.id);
      _peerChanges.add(null);
    }
  }

  void _reconcile(_PeerState s, List<RemoteItem> list) {
    final ids = {for (final r in list) r.id};
    for (final item in store.mirrorsOf(s.peer.id)) {
      // Keep a row whose transfer is still running; expiry removes it after.
      if (!ids.contains(item.id) && item.progress == null) {
        store.remove(item.key);
      }
    }
    for (final r in list) {
      // Known mirrors too, so an eager copy that failed is tried again.
      final item =
          store.addRemote(s.peer.id, s.peer.name, r) ??
          store[itemKey(s.peer.id, r.id)];
      if (item != null && _wantsEagerCopy(item)) _eagerQueue.add(item.key);
    }
    _pumpEager();
  }

  bool _wantsEagerCopy(ShelfItem item) =>
      item.size <= eagerCopyBytes &&
      !item.isReady &&
      item.progress == null &&
      !_downloads.containsKey(item.key) &&
      (_eagerTries[item] ?? 0) < maxEagerTries;

  /// Starts queued eager copies while fewer than [maxEagerDownloads] run,
  /// each from a sender with fewer than [maxEagerPerPeer] running, smallest
  /// first: a text or a screenshot does not wait behind a burst of videos.
  /// An item that expired, was dropped, landed or was tapped while it
  /// waited leaves the queue. A tap ([fetch], [saveTo]) never queues: it
  /// starts at once, and the queue then finds the copy already running.
  void _pumpEager() {
    while (_eagerRunning < maxEagerDownloads) {
      ShelfItem? next;
      for (final key in _eagerQueue.toList()) {
        final item = store[key];
        if (item == null || !_wantsEagerCopy(item)) {
          _eagerQueue.remove(key);
        } else if ((_eagerByPeer[item.originId] ?? 0) < maxEagerPerPeer &&
            (next == null || item.size < next.size)) {
          next = item;
        }
      }
      if (next == null) return;
      _startEager(next);
    }
  }

  void _startEager(ShelfItem item) {
    final key = item.key, peer = item.originId;
    _eagerQueue.remove(key);
    _eagerTries[item] = (_eagerTries[item] ?? 0) + 1;
    _eagerRunning++;
    _eagerByPeer.update(peer, (n) => n + 1, ifAbsent: () => 1);
    final cutOff = Completer<void>();
    final deadline = _deadlines[key] = Timer(
      eagerDeadlineFor(item.size),
      cutOff.complete,
    );
    _fetch(key, cutOff: cutOff.future).catchError((_) => '').whenComplete(() {
      deadline.cancel();
      if (_deadlines[key] == deadline) _deadlines.remove(key);
      _eagerRunning--;
      if (_eagerByPeer.update(peer, (n) => n - 1) == 0) {
        _eagerByPeer.remove(peer);
      }
      _pumpEager();
    });
  }

  /// Drops a gone peer's mirrors that were never copied. One with a
  /// transfer still running keeps its row and progress bar, as in
  /// [_reconcile] and at expiry: a large save runs outside [_downloads],
  /// and dropping its row would invite a second, parallel one when the
  /// peer comes back. [_dropUncopiedIfGone] clears it once it ends.
  void _dropUncopied(String peerId) {
    for (final item in store.mirrorsOf(peerId)) {
      if (!item.isReady &&
          item.progress == null &&
          !_downloads.containsKey(item.key)) {
        store.remove(item.key);
      }
    }
  }

  /// Run when a transfer from [peerId] ends: if the peer went away
  /// meanwhile, its row (and any other left for the same reason) goes now
  /// rather than lingering, uncopied and unfetchable, until it expires.
  void _dropUncopiedIfGone(String peerId) {
    final s = _peers[peerId];
    if (s == null || s.failures >= maxFailures) _dropUncopied(peerId);
  }

  /// Returns the local path of an item, downloading it first if needed.
  /// The file is deleted when the item expires; use [saveTo] to keep it.
  /// A tap waits as long as the transfer takes, so one that finds an eager
  /// copy of the item running lifts that copy's deadline.
  Future<String> fetch(String key) {
    _deadlines.remove(key)?.cancel();
    if (store[key] case final item? when !item.isReady) _tapped.add(key);
    return _fetch(key);
  }

  Future<String> _fetch(String key, {Future<void>? cutOff}) {
    final item = store[key];
    if (item == null) return Future.error(StateError('item expired'));
    if (item.isReady) return Future.value(item.path!);
    // The callback must not return the removed future: whenComplete would
    // wait on it, and it is the future being completed.
    return _downloads[key] ??= _mirror(item, cutOff).whenComplete(() {
      _downloads.remove(key);
      _tapped.remove(key);
      _dropUncopiedIfGone(item.originId);
    });
  }

  /// Puts a copy of an item at [destPath], downloading straight there when
  /// this node does not have it yet. A transfer that has started finishes even
  /// if the item expires meanwhile, so large items are not cut off.
  Future<void> saveTo(String key, String destPath) async {
    final item = store[key];
    if (item == null) throw StateError('item expired');
    if (item.isReady) {
      await File(item.path!).copy(destPath);
      return;
    }
    if (item.size <= eagerCopyBytes) {
      // Small: share the mirror download rather than fetching twice.
      await File(await fetch(key)).copy(destPath);
      return;
    }
    try {
      await _transfer(item, destPath);
    } finally {
      store.setProgress(key, null);
      _dropUncopiedIfGone(item.originId);
    }
  }

  Future<String> _mirror(ShelfItem item, Future<void>? cutOff) async {
    final dest = store.downloadPath(item);
    try {
      await _transfer(item, dest, cutOff: cutOff);
    } catch (_) {
      store.setProgress(item.key, null);
      rethrow;
    }
    if (store[item.key] == null) {
      // Expired while downloading; its directory is already gone.
      await File(dest).delete().catchError((_) => File(dest));
      throw StateError('item expired');
    }
    store.markReady(item.key, dest);
    return dest;
  }

  /// Copies [item] from its sender to [dest]. A tap's transfer (one with
  /// no [cutOff], or an eager copy a tap has joined) that breaks off part
  /// way ([TransferInterrupted]: 15 s without a byte, or the connection
  /// dropped) starts over once, from the first byte, if the sender
  /// answered this node's latest poll of it: what stopped was most likely
  /// this end, a phone that put plop in the background, and a second tap
  /// would have worked. A sender that went quiet itself fails its polls
  /// well inside those 15 s (one every 3 s, 5 s to answer), so its error
  /// comes at once. Eager copies no tap joined are tried again by later
  /// polls instead. Both are decided when it breaks off, not when it
  /// started: a tap may have joined since, and the sender may have been
  /// found afresh meanwhile.
  Future<void> _transfer(ShelfItem item, String dest, {Future<void>? cutOff}) {
    final run = _startOver(item, dest, cutOff: cutOff);
    _transfers.add(run);
    run.whenComplete(() => _transfers.remove(run)).ignore();
    return run;
  }

  Future<void> _startOver(
    ShelfItem item,
    String dest, {
    Future<void>? cutOff,
  }) async {
    var again = true;
    while (true) {
      final s = _peers[item.originId];
      if (s == null) throw StateError('sender is gone');
      try {
        return await _transferOnce(s, item, dest, cutOff: cutOff);
      } on TransferInterrupted {
        final tap = cutOff == null || _tapped.contains(item.key);
        if (!again || !tap || !_answers(item.originId)) rethrow;
        again = false;
      }
    }
  }

  /// Whether [id] answered this node's latest poll of it, as each of
  /// [reachablePeers] has.
  bool _answers(String id) {
    final s = _peers[id];
    return s != null && s.base != null && s.failures == 0;
  }

  Future<void> _transferOnce(
    _PeerState s,
    ShelfItem item,
    String dest, {
    Future<void>? cutOff,
  }) async {
    store.setProgress(item.key, 0);
    var lastStep = 0;
    Object? lastError;
    for (final base in s.candidates) {
      try {
        await client.download(
          base,
          item.id,
          dest,
          expectedSize: item.size,
          cutOff: cutOff,
          selfId: store.nodeId,
          onProgress: (n) {
            final step = item.size == 0 ? 100 : n * 100 ~/ item.size;
            if (step != lastStep) {
              lastStep = step;
              store.setProgress(item.key, step / 100);
            }
          },
        );
        client.confirmReceived(base, item.id, store.nodeId);
        return;
      } on FileSystemException {
        rethrow; // e.g. a full disk: another address will not help
      } catch (e) {
        // A body that broke off on the address that answers polls says
        // more than a stale one refusing afterwards: it is what may start
        // over ([_transfer]).
        if (lastError is! TransferInterrupted) lastError = e;
      }
    }
    throw lastError ?? StateError('no address for sender');
  }

  void _nudgeAll() {
    for (final s in _peers.values) {
      final base = s.candidates.firstOrNull;
      if (base != null) client.nudge(base, store.nodeId);
    }
  }

  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    for (final s in _peers.values) {
      s.poll?.cancel();
    }
    _peers.clear();
    _known.clear();
    _eagerQueue.clear();
    for (final t in _deadlines.values) {
      t.cancel();
    }
    _deadlines.clear();
    // Fails every transfer still running; none can start over, with no
    // peers left. Each deletes its `.part` on the way out, and stop
    // returns only once they all have.
    client.close();
    await Future.wait([
      for (final t in [..._transfers]) t.then((_) {}, onError: (_) {}),
    ]);
    await _peerChanges.close();
  }
}
