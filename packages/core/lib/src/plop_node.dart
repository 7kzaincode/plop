import 'dart:async';
import 'dart:io';

import 'discovery.dart';
import 'item.dart';
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

  Future<ShelfItem> addFile(String path, {String? name}) =>
      store.addFile(path, name: name);
  Future<ShelfItem> addBytes(List<int> bytes, String name) =>
      store.addBytes(bytes, name);
  Future<ShelfItem> addText(String text) => store.addText(text);
  void remove(String key) => store.remove(key);

  /// Local path of an item's bytes, downloading first if needed.
  Future<String> fetch(String key) => engine.fetch(key);

  Future<void> stop() async {
    await discovery.stop();
    await engine.stop();
    await server.stop();
    await store.dispose();
  }
}
