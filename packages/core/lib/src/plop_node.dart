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
  /// [client] is for tests, to watch or fail this node's requests.
  static Future<PlopNode> start({
    required Directory dir,
    required PeerDiscovery discovery,
    required String name,
    int port = 0,
    Duration ttl = defaultTtl,
    int eagerCopyBytes = defaultEagerCopyBytes,
    Duration eagerDeadline = defaultEagerDeadline,
    int maxItemBytes = defaultMaxItemBytes,
    Duration pollInterval = const Duration(seconds: 3),
    NodeClient? client,
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
      client: client,
      eagerCopyBytes: eagerCopyBytes,
      eagerDeadline: eagerDeadline,
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

  /// Peers that reach this node but that it cannot reach: the other side of
  /// [oneWay], usually a firewall on theirs (a Windows PC whose firewall
  /// prompt was dismissed, ufw on Linux). Their lists fail every poll, so
  /// they are not in [peers] and none of their items show; without this
  /// the shelf here reads as "just you" while they show up in [oneWay] on
  /// their own screen.
  ///
  /// A peer counts once it has missed [SyncEngine.maxFailures] polls in a
  /// row (it left [peers] at the first) and has reached this node since
  /// the first of them failed, within [oneWayAfter]. A device that just
  /// went quiet (a phone locking, a laptop going to sleep or off the
  /// Wi-Fi) stops answering and polling at once, so its last contact here
  /// comes before that and it is never listed; nor is one that discovery
  /// keeps listing after it left. Time-based, like [oneWay]: [changes]
  /// fires when a peer stops answering, not when its last contact here
  /// ages out, so a screen that shows this checks it again on a timer.
  List<Peer> get unreachable {
    final now = DateTime.now();
    return [
      for (final p in engine.unreachablePeers)
        if ((server.seenBy[p.id], engine.failingSince(p.id)) case (
          final seen?,
          final since?,
        ) when seen.isAfter(since) && now.difference(seen) <= oneWayAfter)
          p,
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
