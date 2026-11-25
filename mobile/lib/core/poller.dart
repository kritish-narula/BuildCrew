import 'dart:async';

import 'package:flutter/widgets.dart';

/// Polls [task] every [interval] while the app is in the foreground. It
///  * never starts a poll while the previous one is still running (a slow network cannot pile up requests),
///  * stops completely when the app goes to the background and refreshes at once on resume,
///  * is cancelled by [dispose] (call it from the State's dispose).
/// [refreshNow] is for "after an action": it runs immediately, without waiting for the timer.
class Poller with WidgetsBindingObserver {
  Poller(this.interval, this.task, {this.enabled});
  final Duration interval;
  final Future<void> Function() task;

  /// Optional gate (e.g. "tab is visible", "no action in flight"): a tick is skipped while it returns false.
  final bool Function()? enabled;

  Timer? _timer;
  bool _inFlight = false, _background = false, _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_inFlight || _background || !(enabled?.call() ?? true)) return;
    _inFlight = true;
    try {
      await task();
    } catch (_) {
      // polling is best-effort: the screen keeps its previous data
    } finally {
      _inFlight = false;
    }
  }

  /// Run the task now (after an action, pull-to-refresh, resume). Always runs, even if a poll is in flight.
  Future<void> refreshNow() async {
    try {
      await task();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_background) return;
      _background = false;
      _arm();
      unawaited(_tick());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _background = true;
      _timer?.cancel();
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }
}
