import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

/// Where this computer stands with [sharedHost].
enum AliasState {
  /// Not wanted: no web shelf, private mode, or another port than the
  /// shared one.
  off,

  /// Asked for; the runner is probing the network for it.
  claiming,

  /// This computer answers for it.
  held,

  /// Another computer holds it (or there is no network): asked for again
  /// after [Alias.retry] and up to [Alias.jitter] more.
  waiting,

  /// The runner cannot claim names here (no Avahi, a Windows before 1809,
  /// a platform without the channel); the own addresses do instead.
  unavailable,
}

/// Claims [sharedHost] for this computer's LAN address through the
/// runner's "plop/alias" channel, so a phone's home-screen icon saved with
/// it opens the shelf on whichever of the user's computers is on.
///
/// mDNS host names are unique: when two computers are on, one wins and the
/// other hears of a conflict. The loser never renames itself (a plop-2.local
/// would be an address no phone saved). It lets go and asks again every
/// [retry] or so, with jitter so two losers do not keep colliding, and gets
/// the name once the holder has gone (asleep, quit, off the network). The
/// address is looked at every [recheck]: after a wake or a network change it
/// may be a new one, and the old record would point phones nowhere.
///
/// The runner answers "claim" at once and says how it went later, with
/// "state" {state: won, conflict, lost or unavailable, gen}. Each claim
/// carries a new gen, and a state for an older one is ignored: a
/// registration given up while its answer was on the way says nothing about
/// the one that replaced it.
class Alias {
  Alias({
    Future<Object?> Function(String method, [Object? args])? invoke,
    Future<String?> Function()? address,
    Random? random,
  }) : _invoke = invoke ?? _channel.invokeMethod,
       _address = address ?? _bestIPv4,
       _random = random ?? Random();

  static const _channel = MethodChannel('plop/alias');

  /// The app's one claim, wired to the runner by [follow]. On Windows a
  /// [HostResponder] stands in for the runner: the system's own responder
  /// publishes a service pointing at plop.local but never answers for the
  /// name, so a phone's lookup heard nothing.
  static final instance = Platform.isWindows ? _answeredHere() : Alias();

  static Alias _answeredHere() {
    late final Alias alias;
    final responder = HostResponder(
      sharedHost,
      onState: (state, gen) => alias
          .handle(MethodCall('state', {'state': state, 'gen': gen}))
          .ignore(),
    );
    return alias = Alias(invoke: responder.invoke);
  }

  static const retry = Duration(seconds: 8);
  static const jitter = Duration(seconds: 6);
  static const recheck = Duration(seconds: 30);

  /// How long quitting waits for the runner to let go. The runner lets go
  /// at exit anyway (and the OS when the process ends), so this never
  /// holds a quit up for longer.
  static const releaseBudget = Duration(milliseconds: 300);

  final Future<Object?> Function(String method, [Object? args]) _invoke;
  final Future<String?> Function() _address;
  final Random _random;

  AliasState get state => _state;
  AliasState _state = AliasState.off;
  bool get held => _state == AliasState.held;

  /// Fires with each new [state].
  Stream<AliasState> get changes => _changes.stream;
  final _changes = StreamController<AliasState>.broadcast(sync: true);

  bool _wanted = false;
  String? _ip; // what was claimed last, or is being
  int _gen = 0;
  Timer? _retry, _recheck;

  /// Hands the runner's calls to [handle] and claims the name while
  /// [node]'s web shelf is on, outside private mode, on the shared port; a
  /// node that got another port (7567 was taken) has nothing to offer
  /// there. [PlopNode.holdsSharedHost] follows, for the settings panel.
  void follow(PlopNode node) {
    _channel.setMethodCallHandler(handle);
    changes.listen((s) => node.holdsSharedHost = s == AliasState.held);
    void apply() => want(
      node.web.enabled && !node.private.on && node.port == defaultWebPort,
    ).ignore();
    node.private.changes.listen((_) => apply());
    apply();
  }

  /// Claims the name, or lets it go.
  Future<void> want(bool on) async {
    if (on == _wanted) return;
    if (!on) return release();
    _wanted = true;
    _recheck = Timer.periodic(recheck, (_) => _check().ignore());
    await _claim();
  }

  /// Lets the name go and stops asking for it, within [releaseBudget].
  Future<void> release() async {
    _wanted = false;
    _retry?.cancel();
    _recheck?.cancel();
    _gen++;
    _ip = null;
    final was = _state;
    _set(AliasState.off);
    if (was == AliasState.off || was == AliasState.unavailable) return;
    try {
      await _invoke('release').timeout(releaseBudget);
    } catch (_) {
      // Gone already, or slow: it goes with the process either way.
    }
  }

  /// The runner's "state" calls, and "suspend" when the computer is going
  /// to sleep: let go, with a goodbye, and ask again after the wake.
  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'suspend') {
      if (_state == AliasState.held || _state == AliasState.claiming) {
        await _heard('lost', _gen);
      }
      return null;
    }
    if (call.method != 'state') throw MissingPluginException();
    final args = call.arguments as Map?;
    if (args?['state'] case final String s) {
      if (args?['gen'] case final int gen) await _heard(s, gen);
    }
    return null;
  }

  Future<void> _heard(String s, int gen) async {
    if (gen != _gen || !_wanted) return;
    switch (s) {
      case 'won':
        _set(AliasState.held);
      case 'unavailable':
        _unavailable();
      default: // conflict, lost: another computer has it, or had it first
        _gen++;
        _set(AliasState.waiting);
        _later();
        await _invoke('release').catchError((_) => null);
    }
  }

  Future<void> _claim() async {
    _retry?.cancel();
    final ip = await _address();
    if (!_wanted) return;
    if (ip == null) {
      // Off the network: nothing to point the name at yet.
      _ip = null;
      _set(AliasState.waiting);
      return _later();
    }
    _ip = ip;
    final gen = ++_gen;
    _set(AliasState.claiming);
    try {
      await _invoke('claim', {'ip': ip, 'gen': gen});
    } on MissingPluginException {
      _unavailable();
    } catch (_) {
      if (gen != _gen || !_wanted) return;
      _gen++;
      _set(AliasState.waiting);
      _later();
    }
  }

  /// A waiting claim has its own timer; this is for the address under a
  /// claim that went through, or is going through, changing.
  Future<void> _check() async {
    if (_state != AliasState.held && _state != AliasState.claiming) return;
    final ip = await _address();
    if (ip == _ip || !_wanted) return;
    _gen++;
    await _invoke('release').catchError((_) => null);
    await _claim();
  }

  void _later() {
    _retry?.cancel();
    _retry = Timer(retry + jitter * _random.nextDouble(), () {
      if (_wanted) _claim().ignore();
    });
  }

  void _unavailable() {
    _retry?.cancel();
    _recheck?.cancel();
    _set(AliasState.unavailable);
  }

  void _set(AliasState s) {
    if (s == _state) return;
    _state = s;
    _changes.add(s);
  }

  @visibleForTesting
  int get gen => _gen;
}

/// The address the web shelf's QR code would show: the one a phone on the
/// same Wi-Fi most likely reaches.
Future<String?> _bestIPv4() async {
  final ips = await localIPv4s();
  return ips.isEmpty ? null : ips.first;
}
