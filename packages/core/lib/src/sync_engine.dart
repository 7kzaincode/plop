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

  final _peers = <String, _PeerState>{};
  final _downloads = <String, Future<String>>{};
  final _peerChanges = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<void>>[];

  /// Fires when the set of reachable peers changes.
  Stream<void> get peerChanges => _peerChanges.stream;

  /// Peers that answered their last poll.
  List<Peer> get reachablePeers => [
    for (final s in _peers.values)
      if (s.base != null && s.failures == 0) s.peer,
  ];

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
        final list = await client.fetchList(base);
        if (_peers[s.peer.id] != s) return; // went away meanwhile
        final changed = s.base != base || s.failures != 0;
        s
          ..base = base
          ..failures = 0;
        if (changed) _peerChanges.add(null);
        _reconcile(s, list);
        return;
      } catch (_) {
        // try the next address
      }
    }
    s.failures++;
    if (s.failures == maxFailures) {
      _dropUncopied(s.peer.id);
      _peerChanges.add(null);
    }
  }

  void _reconcile(_PeerState s, List<RemoteItem> list) {
    final ids = {for (final r in list) r.id};
    for (final item in store.mirrorsOf(s.peer.id)) {
      if (!ids.contains(item.id)) store.remove(item.key);
    }
    for (final r in list) {
      final item = store.addRemote(s.peer.id, s.peer.name, r);
      if (item != null && item.size <= eagerCopyBytes) {
        fetch(item.key).catchError((_) => '');
      }
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
  Future<String> fetch(String key) {
    final item = store[key];
    if (item == null) return Future.error(StateError('item expired'));
    if (item.isReady) return Future.value(item.path!);
    // The callback must not return the removed future: whenComplete would
    // wait on it, and it is the future being completed.
    return _downloads[key] ??= _download(item).whenComplete(() {
      _downloads.remove(key);
    });
  }

  Future<String> _download(ShelfItem item) async {
    final s = _peers[item.originId];
    if (s == null) throw StateError('sender is gone');
    final dest = store.downloadPath(item);
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
        if (store[item.key] == null) {
          // Expired while downloading.
          await File(dest).delete().catchError((_) => File(dest));
          throw StateError('item expired');
        }
        store.markReady(item.key, dest);
        return dest;
      } catch (e) {
        lastError = e;
        if (e is StateError) rethrow;
      }
    }
    store.setProgress(item.key, null);
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
    client.close();
    await _peerChanges.close();
  }
}
