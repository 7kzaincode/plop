import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

/// This build's version: the release build passes it in
/// (`--dart-define=PLOP_VERSION`, see .github/workflows/release.yml and
/// tool/install_macos.sh); anything else is a dev build.
const appVersion = String.fromEnvironment('PLOP_VERSION', defaultValue: 'dev');

const _repo = '7kzaincode/plop';

/// A release newer than this build, and the file that installs it here.
class Release {
  const Release(this.version, this.page, this.asset);
  final String version;
  final Uri page;

  /// Null where there is nothing to download (Linux): the page instead.
  final Uri? asset;
}

/// Whether version [a] (1.2.3) is newer than [b]. A dev build is never
/// offered an update, and a malformed one is never newer.
@visibleForTesting
bool newer(String a, String b) {
  List<int>? parts(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  }

  final (x, y) = (parts(a), parts(b));
  if (x == null || y == null) return false;
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] > y[i];
  }
  return false;
}

/// Checks GitHub's latest release now and then (the only thing plop asks
/// of the internet; [Settings.checkUpdates] turns it off) and installs it
/// when asked: on Windows the installer runs and reopens plop, on macOS
/// (sandboxed, so it can't replace itself) the disk image lands in
/// Downloads and opens for the drag into Applications, and on Linux the
/// release page opens.
class Updates {
  Updates._();
  static final instance = Updates._();

  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// A newer release, once a check found one.
  final available = ValueNotifier<Release?>(null);

  /// What an update under way is doing ("downloading 40%"), or null.
  final progress = ValueNotifier<String?>(null);

  static const every = Duration(hours: 12);
  Timer? _timer;

  /// Checks now and every [every] while [settings] allow it.
  void follow(Settings settings) {
    if (!supported || appVersion == 'dev') return;
    void tick() {
      if (settings.checkUpdates) check().ignore();
    }

    tick();
    _timer ??= Timer.periodic(every, (_) => tick());
  }

  /// Asks GitHub for the latest release; null when this build is the
  /// latest. Throws when GitHub can't be reached.
  Future<Release?> check() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'plop/$appVersion';
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      );
      req.headers.set('accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw HttpException('${res.statusCode}');
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      final version = (body['tag_name'] as String).replaceFirst('v', '');
      if (!newer(version, appVersion)) return available.value = null;
      Uri? asset;
      for (final a in body['assets'] as List) {
        if ((a as Map)['name'] == _assetName) {
          asset = Uri.parse(a['browser_download_url'] as String);
        }
      }
      return available.value = Release(
        version,
        Uri.parse(body['html_url'] as String),
        asset,
      );
    } finally {
      client.close();
    }
  }

  static String? get _assetName => Platform.isWindows
      ? 'plop-windows-setup.exe'
      : Platform.isMacOS
      ? 'plop-macos.dmg'
      : null;

  /// Installs [r] as this platform can. [quit] ends plop, for the
  /// installer that replaces it on Windows. Throws with what went wrong.
  Future<void> install(Release r, Future<void> Function() quit) async {
    final asset = r.asset;
    // The zip's portable copy has no installer to run: the page instead.
    if (asset == null || Platform.isWindows && !_installed) {
      return _open(r.page.toString());
    }
    final dir = Platform.isMacOS
        ? await getDownloadsDirectory()
        : await getTemporaryDirectory();
    if (dir == null) return _open(r.page.toString());
    final name = Platform.isMacOS
        ? 'plop-${r.version}.dmg'
        : 'plop-${r.version}-setup.exe';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    try {
      await _download(asset, file);
    } finally {
      progress.value = null;
    }
    if (Platform.isMacOS) {
      await Process.run('/usr/bin/open', [file.path]);
      return;
    }
    // Silent, with the one admin prompt Windows asks for; the installer
    // closes plop if it's still running and reopens it when done
    // (packaging/windows/plop.iss).
    await Process.start(file.path, [
      '/SILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
    ], mode: ProcessStartMode.detached);
    await quit();
  }

  /// Whether this is the installer's copy: Inno Setup leaves its
  /// uninstaller next to plop.exe.
  static bool get _installed => File(
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}unins000.exe',
  ).existsSync();

  Future<void> _download(Uri url, File to) async {
    final client = HttpClient()..userAgent = 'plop/$appVersion';
    final part = File('${to.path}.part');
    try {
      final res = await (await client.getUrl(url)).close();
      if (res.statusCode != 200) throw HttpException('${res.statusCode}');
      final total = res.contentLength;
      var got = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress.value = 'downloading ${(got * 100 / total).floor()}%';
          }
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && got != total) throw const HttpException('cut short');
      await part.rename(to.path);
    } catch (_) {
      await part.delete().catchError((_) => part);
      rethrow;
    } finally {
      client.close();
    }
  }

  static Future<void> _open(String url) => Platform.isWindows
      ? Process.run('rundll32', ['url.dll,FileProtocolHandler', url])
      : Process.run(Platform.isMacOS ? '/usr/bin/open' : 'xdg-open', [url]);
}
