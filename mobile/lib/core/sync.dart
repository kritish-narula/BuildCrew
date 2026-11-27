import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'notifier.dart';

/// What `GET /sync` said changed since the previous poll.
class SyncChange {
  const SyncChange({this.jobs = const {}, this.assignments = const {}, this.chats = const {}, this.earnings = false, this.notifications = 0, this.all = false});
  final Set<String> jobs, assignments, chats; // ids (chats = job ids)
  final bool earnings;
  final int notifications;

  /// "Anything may have changed" (first poll, resume after a long pause, or a very large backlog): reload everything.
  final bool all;
  bool get isEmpty => !all && jobs.isEmpty && assignments.isEmpty && chats.isEmpty && !earnings && notifications == 0;

  factory SyncChange.fromJson(Json j, {bool all = false}) {
    Set<String> ids(Object? v) => {for (final x in (v as List? ?? const [])) '$x'};
    final c = (j['changed'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SyncChange(
        jobs: ids(c['jobs']),
        assignments: ids(c['assignments']),
        chats: ids(c['chats']),
        earnings: c['earnings'] == true,
        notifications: (c['notifications'] as num?)?.toInt() ?? 0,
        all: all || j['full'] == true || c['all'] == true);
  }
}

/// ONE light poll for the whole app instead of every screen polling its own list.
///
///  * every [idle] (15 s) in the foreground, every [live] (3 s) while a live screen holds a [boost] (tracking, chat),
///  * sends only a cursor; the server answers with the ids that changed ([SyncChange]) -> [revision] ticks and
///    screens (or [Poller]) reload just what they show,
///  * paused in the background, refreshed at once on resume,
///  * when it sees NEW notifications it fires local system notifications (the app is open or just resumed).
/// If /sync fails (old server, no network) [healthy] turns false and [Poller] falls back to its own timer.
class SyncService with WidgetsBindingObserver {
  SyncService(this.api);

  /// The service of the signed-in session (null when signed out). [Poller] consults it.
  static SyncService? current;

  static const idle = Duration(seconds: 15);
  static const live = Duration(seconds: 3);

  final Api api;
  final ValueNotifier<int> revision = ValueNotifier(0);
  final ValueNotifier<int> unread = ValueNotifier(0);
  SyncChange last = const SyncChange();

  int? _cursor;
  Timer? _timer;
  bool _running = false, _inFlight = false, _background = false;
  DateTime? _lastOk;
  final Set<Object> _boosters = {};
  final Set<String> _announced = {};

  /// Strings for the system notification when the server sends no text (set by the UI layer if wanted).
  String Function(Json n)? titleOf, bodyOf;

  bool get healthy => _running && _lastOk != null && DateTime.now().difference(_lastOk!) < idle * 3;
  Duration get interval => _boosters.isEmpty ? idle : live;

  void start() {
    if (_running) return;
    _running = true;
    current = this;
    _cursor = null;
    _lastOk = null;
    WidgetsBinding.instance.addObserver(this);
    unawaited(pollNow());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _boosters.clear();
    if (identical(current, this)) current = null;
    WidgetsBinding.instance.removeObserver(this);
    unread.value = 0;
    _cursor = null;
    _announced.clear();
  }

  /// A live screen (customer tracking, assignment, chat) asks for fast updates while it is open. Always [release] it.
  void boost(Object holder) {
    final was = _boosters.isEmpty;
    _boosters.add(holder);
    if (was && _running) {
      _schedule();
      unawaited(pollNow());
    }
  }

  void release(Object holder) {
    if (_boosters.remove(holder) && _boosters.isEmpty && _running) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_running || _background) return;
    _timer = Timer(interval, () => unawaited(pollNow()));
  }

  /// Poll now (after an action, on resume). Never overlaps itself.
  Future<void> pollNow() async {
    if (!_running || _inFlight) return;
    _inFlight = true;
    try {
      final j = await api.sync(_cursor);
      final first = _cursor == null;
      _cursor = (j['cursor'] as num?)?.toInt() ?? _cursor;
      _lastOk = DateTime.now();
      final ch = SyncChange.fromJson(j);
      final u = (j['unread'] as num?)?.toInt();
      final before = unread.value;
      if (u != null) unread.value = u;
      if (first) {
        // Baseline: remember where we are. Do not spam notifications for things that happened before we looked.
        last = const SyncChange(all: true);
        revision.value++;
        await _seedAnnounced();
      } else if (!ch.isEmpty) {
        last = ch;
        revision.value++;
        if (ch.notifications > 0 || (u != null && u > before)) unawaited(_announceNew());
      }
    } catch (_) {
      // best-effort: keep the last data, try again on the next tick
    } finally {
      _inFlight = false;
      _schedule();
    }
  }

  Future<void> _seedAnnounced() async {
    try {
      for (final n in await api.notifications(limit: 30)) {
        _announced.add('${n['id']}');
      }
    } catch (_) {}
  }

  /// Local system notification for every unread notification we have not shown yet.
  Future<void> _announceNew() async {
    try {
      final items = await api.notifications(limit: 10);
      for (final n in items.reversed) {
        final id = '${n['id']}';
        if (n['read'] == true || !_announced.add(id)) continue;
        final title = titleOf?.call(n) ?? '${n['title'] ?? 'BuildCrew'}';
        final body = bodyOf?.call(n) ?? '${n['body'] ?? ''}';
        await AppNotifier.instance.show(id: id.hashCode & 0x7fffffff, title: title, body: body, payload: _route(n));
      }
    } catch (_) {}
  }

  static String _route(Json n) => (n['link'] as String?) ?? '/notifications';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_running) return;
    if (state == AppLifecycleState.resumed) {
      if (!_background) return;
      _background = false;
      unawaited(pollNow()); // refresh at once; also fires notifications that arrived while away
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _background = true;
      _timer?.cancel();
    }
  }

  /// Cursor persistence is deliberately NOT done: a fresh baseline on launch is cheaper than replaying old changes.
  @visibleForTesting
  int? get cursor => _cursor;
}
