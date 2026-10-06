import 'dart:async';
import 'dart:io';

import 'discovery.dart';
import 'item.dart';
import 'node_client.dart';
import 'node_server.dart';
import 'shelf_store.dart';
import 'sync_engine.dart';

/// One running node: store, HTTP server, sync engine and discovery, wired
/// together.
class PlopNode {
  PlopNode._(this.store, this.server, this.engine, this.discovery);

  final ShelfStore store;
  final NodeServer server;
  final SyncEngine engine;
  final PeerDiscovery discovery;

  /// [dir] is wiped on start; give each node on one machine its own.
  static Future<PlopNode> start({
    required Directory dir,
    required PeerDiscovery discovery,
    required String name,
    int port = 0,
    Duration ttl = defaultTtl,
    int eagerCopyBytes = defaultEagerCopyBytes,
    int maxItemBytes = defaultMaxItemBytes,
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final store = ShelfStore(
      nodeId: randomId(),
      nodeName: name,
      dir: dir,
      ttl: ttl,
      maxItemBytes: maxItemBytes,
    );
    await store.init();
    final engine = SyncEngine(
      store: store,
      discovery: discovery,
      eagerCopyBytes: eagerCopyBytes,
      pollInterval: pollInterval,
    );
    final server = NodeServer(store, onNudge: engine.onNudge);
    await server.start(port: port);
    engine.start();
    await discovery.start(
      LocalNode(
        id: store.nodeId,
        name: name,
        port: server.port,
        ips: await localIPv4s(),
      ),
    );
    return PlopNode._(store, server, engine, discovery);
  }

  String get id => store.nodeId;
  int get port => server.port;
  List<ShelfItem> get items => store.items;
  List<Peer> get peers => engine.reachablePeers;

  /// Name of a peer by id, for showing who an item's [ShelfItem.receivedBy]
  /// lists; null once that peer has left the network.
  String? peerName(String id) => engine.peerName(id);

  /// How long a reachable peer may go without reaching us before it counts
  /// as one-way. Peers poll every 3 s.
  static const oneWayAfter = Duration(seconds: 12);

  /// Peers this node can reach that cannot reach it back: they see our list
  /// is unavailable, usually because a firewall here blocks inbound
  /// connections. Only flagged after [oneWayAfter] of being reachable.
  List<Peer> get oneWay {
    final now = DateTime.now();
    return [
      for (final p in engine.reachablePeers)
        if (now.difference(_lastContact(p.id, now)) > oneWayAfter) p,
    ];
  }

  /// The later of: since when we have reached [id], and when it last reached
  /// us. A `seenBy` entry older than `okSince` predates the current reachable
  /// window (the peer slept or dropped off Wi-Fi), so it must not count, or
  /// a phone coming back from sleep is flagged until its first poll lands.
  DateTime _lastContact(String id, DateTime now) {
    final ok = engine.okSince(id) ?? now;
    final seen = server.seenBy[id];
    return seen != null && seen.isAfter(ok) ? seen : ok;
  }

  /// Brings networking back after the app was suspended: re-binds the
  /// server if the OS reclaimed its socket, re-advertises on mDNS when asked
  /// to, and polls every peer right away.
  Future<void> revive({bool rebroadcast = false}) async {
    var listening = false;
    final probe = NodeClient();
    try {
      await probe
          .fetchList(Uri(scheme: 'http', host: '127.0.0.1', port: port), id)
          .timeout(const Duration(seconds: 1));
      listening = true;
    } catch (_) {
      // Not listening any more.
    } finally {
      probe.close();
    }
    if (!listening) {
      await server.restart();
      rebroadcast = true; // the port may have changed
    }
    if (rebroadcast) {
      await discovery.rebroadcast(
        LocalNode(
          id: id,
          name: store.nodeName,
          port: port,
          ips: await localIPv4s(),
        ),
      );
    }
    engine.onNudge(null);
  }

  /// Fires when items or peers change.
  Stream<void> get changes {
    late final StreamController<void> c;
    final subs = <StreamSubscription<void>>[];
    c = StreamController<void>.broadcast(
      onListen: () => subs
        ..add(store.changes.listen(c.add))
        ..add(engine.peerChanges.listen(c.add)),
      onCancel: () {
        for (final s in subs) {
          s.cancel();
        }
        subs.clear();
      },
    );
    return c.stream;
  }

  /// Lifetime for items added from now on.
  Duration get ttl => store.ttl;
  set ttl(Duration d) => store.ttl = d;

  /// Adds a file or a folder.
  Future<ShelfItem> addPath(String path) => store.addPath(path);
  Future<ShelfItem> addFile(String path, {String? name}) =>
      store.addFile(path, name: name);
  Future<ShelfItem> addBytes(List<int> bytes, String name) =>
      store.addBytes(bytes, name);
  Future<ShelfItem> addText(String text) => store.addText(text);
  void remove(String key) => store.remove(key);

  /// Local path of an item's bytes, downloading first if needed.
  Future<String> fetch(String key) => engine.fetch(key);

  /// Copies an item to [destPath]; see [SyncEngine.saveTo].
  Future<void> saveTo(String key, String destPath) =>
      engine.saveTo(key, destPath);

  Future<void> stop() async {
    await discovery.stop();
    await engine.stop();
    await server.stop();
    await store.dispose();
  }
}
