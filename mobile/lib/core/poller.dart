import 'dart:async';

import 'package:flutter/widgets.dart';

import 'sync.dart';

/// Polls [task] every [interval] while the app is in the foreground. It
///  * never starts a poll while the previous one is still running (a slow network cannot pile up requests),
///  * stops completely when the app goes to the background and refreshes at once on resume,
///  * is cancelled by [dispose] (call it from the State's dispose).
/// [refreshNow] is for "after an action": it runs immediately, without waiting for the timer.
///
/// Efficient sync: when the signed-in session has a healthy [SyncService], a tick does NOT hit the network on its own.
/// The task runs when `/sync` reported a change since this poller last ran, or at most every `interval x 3` as a safety
/// net. A poller with `interval <= 3 s` (live tracking, assignment, chat) also asks the service to poll fast
/// ([SyncService.boost]) while it exists. If /sync is unavailable the classic fixed-interval behaviour returns.
class Poller with WidgetsBindingObserver {
  Poller(this.interval, this.task, {this.enabled});
  final Duration interval;
  final Future<void> Function() task;

  /// Optional gate (e.g. "tab is visible", "no action in flight"): a tick is skipped while it returns false.
  final bool Function()? enabled;

  Timer? _timer;
  bool _inFlight = false, _background = false, _started = false, _boosted = false;
  int _seenRevision = -1;
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  SyncService? _sync;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _sync = SyncService.current;
    _sync?.revision.addListener(_onRevision);
    if (_sync != null && interval <= SyncService.live) {
      _boosted = true;
      _sync!.boost(this);
    }
    _seenRevision = _sync?.revision.value ?? -1;
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void _onRevision() {
    // The server said something changed: reload now (do not wait for our timer).
    if (!_started || _background) return;
    unawaited(_tick(force: true));
  }

  Future<void> _tick({bool force = false}) async {
    if (_inFlight || _background || !(enabled?.call() ?? true)) return;
    final s = _sync;
    if (s != null && s.healthy) {
      final changed = s.revision.value != _seenRevision;
      final stale = DateTime.now().difference(_lastRun) >= interval * 3;
      if (!changed && !stale && !force) return; // nothing new on the server: no request, no rebuild
      _seenRevision = s.revision.value;
    }
    _inFlight = true;
    try {
      await task();
      _lastRun = DateTime.now();
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
      _lastRun = DateTime.now();
    } catch (_) {}
    unawaited(_sync?.pollNow()); // pick up the consequences of our own write (and the badge) right away
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_background) return;
      _background = false;
      _arm();
      _lastRun = DateTime.fromMillisecondsSinceEpoch(0); // resume always refreshes
      unawaited(_tick());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _background = true;
      _timer?.cancel();
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _sync?.revision.removeListener(_onRevision);
    if (_boosted) _sync?.release(this);
    _boosted = false;
    _sync = null;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }
}
