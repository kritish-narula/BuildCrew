import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'updater.dart';

/// The ONE owner of flutter_local_notifications (the plugin keeps a single tap callback, so the updater and the
/// sync service must share it). Tap payloads: `update` opens the update sheet; any `/route` is a go_router deep link
/// (`/job/:id`, `/assignment/:id?job=:jobId`, `/chat/:jobId/:withUser`, `/notifications`).
class AppNotifier {
  AppNotifier._();
  static final instance = AppNotifier._();

  /// Channel id shared with the (optional) FCM push payload, so background pushes look identical.
  static const channelId = 'buildcrew_updates';

  final plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  /// Set by main(): opens a deep link in the router. A tap that arrives before it is set is replayed on assignment.
  void Function(String route)? _onRoute;
  String? _pendingRoute;

  set onRoute(void Function(String route)? f) {
    _onRoute = f;
    final p = _pendingRoute;
    if (f != null && p != null) {
      _pendingRoute = null;
      f(p);
    }
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => _dispatch(r.payload),
      );
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) _dispatch(launch?.notificationResponse?.payload);
    } catch (e) {
      debugPrint('notifier init failed: $e'); // notifications are a nicety; never block startup
    }
  }

  void _dispatch(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (payload == 'update') {
      Updater.instance.requestSheet();
      return;
    }
    final f = _onRoute;
    if (f == null) {
      _pendingRoute = payload;
    } else {
      f(payload);
    }
  }

  Future<bool> requestPermission() async {
    try {
      return await plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission() ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// A system notification (heads-up). [id] should be stable per source so a repeat replaces instead of stacking.
  Future<void> show({required int id, required String title, required String body, String? payload, String channel = channelId}) async {
    try {
      await plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(channel, channel == channelId ? 'Job updates' : 'App updates',
              channelDescription: 'Quotes, payments, messages and job progress',
              importance: Importance.high,
              priority: Priority.high,
              styleInformation: BigTextStyleInformation(body)),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }
}
