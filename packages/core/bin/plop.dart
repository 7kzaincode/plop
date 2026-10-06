// Headless plop node, for testing against the app.
//
//   dart run plop_core:plop --peer 192.168.1.20:50725 --text hello --file a.png
//
// It polls the given peers directly. On macOS it also advertises itself with
// `dns-sd`, so apps on the network find it and mirror its items.
import 'dart:async';
import 'dart:io';

import 'package:plop_core/plop_core.dart';

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  List<String> all(String name) => [
    for (var i = 0; i < args.length - 1; i++)
      if (args[i] == '--$name') args[i + 1],
  ];

  final name = opt('name') ?? 'plop-cli';
  final discovery = StaticDiscovery();
  final node = await PlopNode.start(
    dir: Directory('${Directory.systemTemp.path}/plop-cli-$pid'),
    discovery: discovery,
    name: name,
    ttl: Duration(seconds: int.parse(opt('ttl') ?? '120')),
  );
  print('node ${node.id} listening on ${node.port}');

  for (final (i, p) in all('peer').indexed) {
    final [host, port] = p.split(':');
    // Ids are learned from mDNS in the app; here any unique id works.
    discovery.add(
      Peer(id: 'peer$i', name: p, hosts: [host], port: int.parse(port)),
    );
  }

  Process? dnsSd;
  if (Platform.isMacOS) {
    final ips = await localIPv4s();
    dnsSd = await Process.start('dns-sd', [
      '-R', name, '_plop._tcp', 'local', '${node.port}',
      'id=${node.id}', 'v=1', 'name=$name', 'ips=${ips.join(',')}',
    ]);
  }

  for (final t in all('text')) {
    await node.addText(t);
  }
  for (final f in all('file')) {
    await node.addFile(f);
  }

  var last = '';
  node.changes.listen((_) {
    final s = node.items
        .map(
          (i) =>
              '  ${i.originId == node.id ? 'mine' : 'from ${i.originName}'}'
              ' ${i.kind.name} "${i.name}" ${i.size}B'
              ' ${i.isReady ? 'ready ${i.path}' : 'not copied'}',
        )
        .join('\n');
    final line = 'peers: ${node.peers.map((p) => p.name).join(', ')}\n$s';
    if (line != last) print('${DateTime.now().toIso8601String()} $line');
    last = line;
  });

  final secs = int.tryParse(opt('for') ?? '');
  await (secs == null
      ? ProcessSignal.sigint.watch().first
      : Future<void>.delayed(Duration(seconds: secs)));
  dnsSd?.kill();
  await node.stop();
  exit(0);
}
