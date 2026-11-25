/// Build-time configuration (passed by CI with --dart-define). No secrets ever live here:
/// anything compiled into an APK can be extracted, so payment/API secrets stay on the server.
class AppConfig {
  /// Empty → the app runs in DEMO mode against an in-memory copy of the seed data, so the APK
  /// is usable before the backend is deployed.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Static release manifest (no GitHub API rate limits): CI uploads update.json to every release.
  static const updateManifestUrl = String.fromEnvironment(
    'UPDATE_MANIFEST_URL',
    defaultValue: 'https://github.com/kritish-narula/BuildCrew/releases/latest/download/update.json',
  );

  static const supportPhone = String.fromEnvironment('SUPPORT_PHONE', defaultValue: '+911800000000');

  static bool get isDemo => apiBaseUrl.isEmpty;
}
