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
    this.pollInterval = const Duration(seconds: 3),
  }) : client = client ?? NodeClient();

  final ShelfStore store;
  final PeerDiscovery discovery;
  final NodeClient client;
  final int eagerCopyBytes;
  final Duration pollInterval;

  /// After this many failed polls in a row, a peer counts as gone.
  static const maxFailures = 3;

  /// Eager copies running at once. A burst of small items would otherwise
  /// open a socket and a `.part` file each, all in the same tick, and run
  /// a phone or a Mac app out of file descriptors (256 by default), failing
  /// most of the copies and this node's own server with them.
  static const maxEagerDownloads = 4;

  /// Eager copies started per item. One that fails is queued again by the
  /// next poll; after this many, the item waits for a tap like a large one.
  static const maxEagerTries = 3;

  final _peers = <String, _PeerState>{};
  final _downloads = <String, Future<String>>{};

  /// Keys of items waiting for an eager copy, oldest first; a set, since
  /// every poll queues whatever is still uncopied.
  final _eagerQueue = <String>{};
  var _eagerRunning = 0;

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

  /// Since when [id] has been continuously reachable; null if it is not.
  DateTime? okSince(String id) => _peers[id]?.okSince;

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
        final s = _peers[peer.id];
        if (s != null) {
          s.peer = peer;
        } else {
          final s = _peers[peer.id] = _PeerState(peer);
          s.poll = Timer.periodic(pollInterval, (_) => _refresh(s));
        }
        _refresh(_peers[peer.id]!);
      case PeerDown(:final id):
        final s = _peers.remove(id);
        if (s == null) return;
        s.poll?.cancel();
        _dropUncopied(id);
        _peerChanges.add(null);
    }
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
        final list = await client.fetchList(base, store.nodeId);
        if (_peers[s.peer.id] != s) return; // went away meanwhile
        final changed = s.base != base || s.failures != 0;
        s
          ..base = base
          ..failures = 0
          ..okSince ??= DateTime.now();
        if (changed) _peerChanges.add(null);
        _reconcile(s, list);
        return;
      } catch (_) {
        // try the next address
      }
    }
    s.failures++;
    s.okSince = null;
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

  /// Starts queued eager copies while fewer than [maxEagerDownloads] run.
  /// An item that expired, was dropped, landed or was tapped while it
  /// waited is passed over. A tap ([fetch], [saveTo]) never queues: it
  /// starts at once, and the queue then finds the copy already running.
  void _pumpEager() {
    while (_eagerRunning < maxEagerDownloads && _eagerQueue.isNotEmpty) {
      final key = _eagerQueue.first;
      _eagerQueue.remove(key);
      final item = store[key];
      if (item == null || !_wantsEagerCopy(item)) continue;
      _eagerTries[item] = (_eagerTries[item] ?? 0) + 1;
      _eagerRunning++;
      fetch(key).catchError((_) => '').whenComplete(() {
        _eagerRunning--;
        _pumpEager();
      });
    }
  }

  void _dropUncopied(String peerId) {
    for (final item in store.mirrorsOf(peerId)) {
      if (!item.isReady && !_downloads.containsKey(item.key)) {
        store.remove(item.key);
      }
    }
  }

  /// Returns the local path of an item, downloading it first if needed.
  /// The file is deleted when the item expires; use [saveTo] to keep it.
  Future<String> fetch(String key) {
    final item = store[key];
    if (item == null) return Future.error(StateError('item expired'));
    if (item.isReady) return Future.value(item.path!);
    // The callback must not return the removed future: whenComplete would
    // wait on it, and it is the future being completed.
    return _downloads[key] ??= _mirror(item).whenComplete(() {
      _downloads.remove(key);
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
    }
  }

  Future<String> _mirror(ShelfItem item) async {
    final dest = store.downloadPath(item);
    try {
      await _transfer(item, dest);
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

  Future<void> _transfer(ShelfItem item, String dest) async {
    final s = _peers[item.originId];
    if (s == null) throw StateError('sender is gone');
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
        lastError = e;
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
    _eagerQueue.clear();
    client.close();
    await _peerChanges.close();
  }
}
