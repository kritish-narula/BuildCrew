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

  static const supportPhone = kSupportPhone;

  static bool get isDemo => apiBaseUrl.isEmpty;
}

/// Owner support line (call / WhatsApp). Display form: +91 79734 93558.
const supportPhone = '+917973493558';
const supportWhatsApp = '917973493558';
const kSupportPhone = supportPhone;
const supportPhoneDisplay = '+91 79734 93558';
