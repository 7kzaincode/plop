import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';

/// How long to wait for a peer before saying none were found.
const _peerGrace = Duration(seconds: 6);

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key, required this.node});

  final PlopNode node;

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  late final StreamSubscription<void> _changes;
  late final Timer _tick;
  final _started = DateTime.now();
  bool _dragging = false;

  PlopNode get node => widget.node;

  @override
  void initState() {
    super.initState();
    _changes = node.changes.listen((_) => setState(() {}));
    // Drives the countdowns.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _changes.cancel();
    _tick.cancel();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final msg = await action();
      if (msg != null) {
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<String?> _addPaths(Iterable<String> paths) async {
    for (final p in paths) {
      await node.addFile(p);
    }
    return null;
  }

  Future<String?> _paste() async {
    if (await pasteInto(node)) return null;
    return 'Nothing to paste';
  }

  @override
  Widget build(BuildContext context) {
    final items = node.items;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
            _run(_paste),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
            _run(_paste),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 2, child: _dropArea(context)),
                  const SizedBox(height: 12),
                  _peerStatus(context),
                  const SizedBox(height: 8),
                  Expanded(
                    flex: 3,
                    child: items.isEmpty
                        ? _empty(context)
                        : ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) => _row(context, items[i]),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dropArea(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final area = Material(
      color: _dragging
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _run(() async => _addPaths(await pickFiles())),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.file_upload_outlined,
                    size: 48,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    canDrop ? 'Drop or tap to add' : 'Tap to add',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: TextButton.icon(
                onPressed: () => _run(_paste),
                icon: const Icon(Icons.content_paste),
                label: const Text('Paste'),
              ),
            ),
          ],
        ),
      ),
    );
    return wrapDropTarget(
      child: area,
      onHover: (h) => setState(() => _dragging = h),
      onDrop: (paths) => _run(() => _addPaths(paths)),
    );
  }

  Widget _peerStatus(BuildContext context) {
    final n = node.peers.length;
    final style = Theme.of(context).textTheme.bodySmall;
    if (n > 0) {
      return Text(
        n == 1 ? '1 device nearby' : '$n devices nearby',
        style: style,
      );
    }
    if (DateTime.now().difference(_started) < _peerGrace) {
      return Text('Looking for nearby devices…', style: style);
    }
    return Text(
      'No other devices found. They need plop open on this same Wi-Fi. '
      'Some networks (guest, hotel, campus) block devices from seeing each other.',
      style: style?.copyWith(color: Theme.of(context).colorScheme.error),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'Drop something here. Anyone on this Wi-Fi with the app open '
        'can grab it for 2 minutes.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );

  Widget _row(BuildContext context, ShelfItem item) {
    final theme = Theme.of(context);
    final mine = item.originId == node.id;
    final left = item.remaining;
    // Peers use the same default TTL, so this is the right scale for mirrors too.
    final fraction = (left.inMilliseconds / node.store.ttl.inMilliseconds)
        .clamp(0.0, 1.0);
    final from = mine ? 'You' : item.originName;
    final keepOpen = mine && item.size > defaultEagerCopyBytes;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: mine ? null : () => _run(() => grab(context, node, item)),
        child: Column(
          children: [
            ListTile(
              leading: Icon(_iconFor(item)),
              title: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (item.kind == ItemKind.file) formatSize(item.size),
                  'from $from',
                  if (keepOpen) 'keep plop open until it is grabbed',
                ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _countdown(left),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (mine)
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close),
                      onPressed: () => node.remove(item.key),
                    ),
                ],
              ),
            ),
            LinearProgressIndicator(
              value: item.progress ?? fraction,
              minHeight: 3,
              color: item.progress != null ? theme.colorScheme.tertiary : null,
              backgroundColor: Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(ShelfItem item) {
    if (item.kind == ItemKind.text) return Icons.notes;
    if (item.mime.startsWith('image/')) return Icons.image_outlined;
    if (item.mime.startsWith('video/')) return Icons.movie_outlined;
    if (item.mime.startsWith('audio/')) return Icons.audiotrack;
    return Icons.insert_drive_file_outlined;
  }

  static String _countdown(Duration d) {
    final s = (d.inMilliseconds / 1000).ceil();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 10 ? 0 : 1)} ${units[u]}';
}
