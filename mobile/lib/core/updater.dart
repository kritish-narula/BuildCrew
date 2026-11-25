import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// In-app self-update for APKs distributed through GitHub Releases.
///
/// How "update instead of reinstall" works:
///  * Every release is signed with the SAME release key (CI secret) and has a HIGHER
///    versionCode (CI run number). Android therefore treats the new APK as an *update*:
///    the app is replaced in place and all data (login, language, drafts) is kept.
///  * The app reads `update.json` from the latest release, picks the APK for this phone's CPU
///    (arm64 / armv7 — ~2× smaller than a universal APK, important on prepaid data), downloads
///    it, verifies its SHA-256 against the manifest, then hands it to Android's installer.
///  * Android itself re-checks the signature: an APK signed by anyone else is refused, so even a
///    tampered download that somehow matched the hash could not replace the app.
///
/// Checks run on launch and when the app returns to the foreground (throttled to every 6 h).
enum UpdateStage { idle, downloading, verifying, installing, needsPermission, failed, tampered }

class UpdateInfo {
  UpdateInfo({required this.versionName, required this.versionCode, required this.url, required this.sha256,
      required this.sizeBytes, required this.notes, required this.required});
  final String versionName, url, sha256;
  final int versionCode, sizeBytes;
  final Map<String, String> notes;
  final bool required;

  String notesFor(String lang) => notes[lang] ?? notes['en'] ?? '';
  String get sizeLabel => '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class Updater extends ChangeNotifier {
  Updater._();
  static final instance = Updater._();

  static const _channel = MethodChannel('buildcrew/updater');
  final _notifications = FlutterLocalNotificationsPlugin();
  final _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));

  UpdateInfo? available;
  UpdateStage stage = UpdateStage.idle;
  double progress = 0;
  String currentVersion = '';
  int currentCode = 0;
  bool openSheetRequested = false; // set when the user taps the notification
  DateTime? _lastCheck;
  CancelToken? _cancel;

  Future<void> init() async {
    final info = await PackageInfo.fromPlatform();
    currentVersion = info.version;
    currentCode = int.tryParse(info.buildNumber) ?? 0;
    try {
      await _notifications.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload == 'update') {
            openSheetRequested = true;
            notifyListeners();
          }
        },
      );
      final launch = await _notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true && launch?.notificationResponse?.payload == 'update') {
        openSheetRequested = true;
      }
    } catch (_) {/* notifications are a nicety; never block startup */}
  }

  /// Android 13+ needs runtime permission for notifications. Ask after login, not on first launch.
  Future<void> requestNotificationPermission() async {
    try {
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// Returns the update if a newer build exists. Network failures are silent (offline is normal).
  Future<UpdateInfo?> check({bool force = false}) async {
    if (!Platform.isAndroid) return null;
    if (!force && _lastCheck != null && DateTime.now().difference(_lastCheck!) < const Duration(hours: 6)) {
      return available;
    }
    try {
      final res = await _dio.get<Map<String, dynamic>>(AppConfig.updateManifestUrl,
          options: Options(responseType: ResponseType.json, headers: {'Cache-Control': 'no-cache'}));
      _lastCheck = DateTime.now();
      final m = res.data!;
      final abi = await _channel.invokeMethod<String>('abi') ?? 'arm64-v8a';
      final apks = (m['apks'] as Map).cast<String, dynamic>();
      final apk = (apks[abi] ?? apks['arm64-v8a'] ?? apks.values.first) as Map;
      final code = (apk['versionCode'] as num).toInt();
      // Split-per-ABI builds encode versionCode as abi*1000 + build; compare the build part.
      final myBuild = currentCode % 1000;
      final newBuild = code % 1000;
      if (newBuild <= myBuild) {
        available = null;
      } else {
        available = UpdateInfo(
          versionName: m['versionName'] as String,
          versionCode: code,
          url: apk['url'] as String,
          sha256: (apk['sha256'] as String).toLowerCase(),
          sizeBytes: (apk['size'] as num).toInt(),
          notes: ((m['notes'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, v as String)),
          required: myBuild < ((m['minSupportedBuild'] as num?)?.toInt() ?? 0),
        );
      }
      notifyListeners();
      return available;
    } catch (e) {
      debugPrint('update check failed: $e');
      return available;
    }
  }

  /// Shows the system notification once per version.
  Future<void> notifyOnce(String title, String body) async {
    final u = available;
    if (u == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'notified_${u.versionCode}';
    if (prefs.getBool(key) == true) return;
    try {
      await _notifications.show(
        7001,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails('app_updates', 'App updates',
              channelDescription: 'New versions of BuildCrew', importance: Importance.high, priority: Priority.high),
        ),
        payload: 'update',
      );
      await prefs.setBool(key, true);
    } catch (_) {}
  }

  Future<void> start() async {
    final u = available;
    if (u == null || stage == UpdateStage.downloading) return;
    final canInstall = await _channel.invokeMethod<bool>('canInstall') ?? false;
    if (!canInstall) {
      _set(UpdateStage.needsPermission);
      return;
    }
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    for (final old in dir.listSync()) {
      old.deleteSync(); // keep at most one APK on a low-storage phone
    }
    final file = File('${dir.path}/BuildCrew-${u.versionCode}.apk');
    try {
      progress = 0;
      _set(UpdateStage.downloading);
      _cancel = CancelToken();
      await _dio.download(u.url, file.path, cancelToken: _cancel, onReceiveProgress: (got, total) {
        final t = total > 0 ? total : u.sizeBytes;
        progress = t > 0 ? got / t : 0;
        notifyListeners();
      });
      _set(UpdateStage.verifying);
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != u.sha256) {
        await file.delete();
        _set(UpdateStage.tampered);
        return;
      }
      _set(UpdateStage.installing);
      await _channel.invokeMethod('install', {'path': file.path});
    } catch (e) {
      debugPrint('update failed: $e');
      _set(UpdateStage.failed);
    }
  }

  Future<void> openInstallPermissionSettings() => _channel.invokeMethod('openInstallSettings');

  void cancel() {
    _cancel?.cancel();
    _set(UpdateStage.idle);
  }

  void consumeSheetRequest() => openSheetRequested = false;

  void _set(UpdateStage s) {
    stage = s;
    notifyListeners();
  }
}
