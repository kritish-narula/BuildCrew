/// Hook for BACKGROUND push (FCM). Disabled by default: the app ships no Firebase packages, so while it is closed the user
/// only gets what the OS can show from the last sync. Everything else is ready:
///   * the backend has `POST /me/push-token` and an FCM HTTP v1 sender (enabled by `FCM_SERVICE_ACCOUNT_JSON`),
///   * payloads carry `data.link` (a go_router path) and use channel `buildcrew_updates`.
/// TODO(push): add `firebase_core` + `firebase_messaging`, put google-services.json in android/app (CI secret), then in
/// main() before runApp:
///   PushClient.tokenProvider = () => FirebaseMessaging.instance.getToken();
///   FirebaseMessaging.onMessage / onMessageOpenedApp -> AppNotifier.instance.show(...) / router.push(msg.data['link']).
/// See README "Push notifications".
class PushClient {
  PushClient._();

  /// Returns the device's FCM token, or null when push is not configured.
  static Future<String?> Function()? tokenProvider;

  static bool get enabled => tokenProvider != null;

  static Future<String?> token() async {
    try {
      return await tokenProvider?.call();
    } catch (_) {
      return null;
    }
  }
}
