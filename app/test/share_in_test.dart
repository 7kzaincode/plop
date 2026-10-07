import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plop/share_in.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  late Directory root;
  late PlopNode node;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plop_share');
    node = await PlopNode.start(
      dir: Directory('${root.path}/store'),
      discovery: StaticDiscovery(),
      name: 'me',
    );
  });

  tearDown(() async {
    await node.stop();
    await root.delete(recursive: true);
  });

  /// What [ShareIn.take] says of [shared].
  Future<List<String>> take(Map<String, Object?> shared) async {
    final said = <String>[];
    await ShareIn.take(node, shared, said.add);
    return said;
  }

  // A Dock drop or a share of several things: one that fails used to stop
  // the rest, and the message only named the first error.
  test('what was shared goes on past a path that fails', () async {
    final a = File('${root.path}/a.txt')..writeAsStringSync('a');
    final b = File('${root.path}/b.txt')..writeAsStringSync('b');
    final said = await take({
      'paths': ['${root.path}/moved.txt', a.path, b.path],
    });
    expect(node.items.map((i) => i.name), unorderedEquals(['a.txt', 'b.txt']));
    expect(said, ["can't access moved.txt"]);

    // Two that fail, and one Android could not read at all.
    final c = File('${root.path}/c.txt')..writeAsStringSync('c');
    expect(
      await take({
        'paths': ['${root.path}/x.txt', '${root.path}/y.txt', c.path],
        'failed': 1,
      }),
      ["can't access x.txt · 2 more failed"],
    );
  });

  test(
    'what was shared says it landed, and what Android could not read',
    () async {
      final a = File('${root.path}/a.txt')..writeAsStringSync('a');
      expect(
        await take({
          'paths': [a.path],
        }),
        ['plopped'],
      );
      expect(
        await take({
          'paths': [a.path],
          'failed': 2,
        }),
        ['plopped · 2 failed'],
      );
      expect(await take({'paths': [], 'failed': 1}), [
        "couldn't read what was shared",
      ]);
      // Text stands in only when there was no file.
      expect(await take({'paths': [], 'text': 'hi'}), ['plopped']);
      expect(node.items.where((i) => i.kind == ItemKind.text), hasLength(1));
    },
  );
}
