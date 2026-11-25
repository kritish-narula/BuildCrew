import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'config.dart';

/// App-wide session state. Drives routing (see router.dart): language → role → phone/OTP → home.
///
/// Security: the auth token lives in Android Keystore-backed secure storage (never in plain
/// SharedPreferences), and the manifest disables cloud backup so it can't be restored elsewhere.
class AppState extends ChangeNotifier {
  AppState._(this._prefs, this.api);

  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  final SharedPreferences _prefs;
  final Api api;

  String? language; // null until S1 is done
  String? roleIntent; // chosen on the role screen, used only when registering a new number
  String? token;
  SessionUser? user;
  String? pendingPhone;

  bool get loggedIn => token != null && user != null;
  bool get isDemo => AppConfig.isDemo;

  static Future<AppState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = AppState._(prefs, Api.create());
    s.language = prefs.getString('language');
    s.roleIntent = prefs.getString('roleIntent');
    try {
      s.token = await _secure.read(key: 'token');
      final u = await _secure.read(key: 'user');
      if (u != null) s.user = SessionUser.fromJson(jsonDecode(u) as Map<String, dynamic>);
    } catch (_) {
      // Keystore can be wiped (e.g. lock-screen change on some OEMs) → just log in again.
      s.token = null;
      s.user = null;
    }
    s.api.token = s.token;
    return s;
  }

  Future<void> setLanguage(String code) async {
    language = code;
    await _prefs.setString('language', code);
    notifyListeners();
    if (loggedIn && !isDemo) {
      try {
        user = await api.setLanguage(code); // server-side SMS/errors switch too
        await _secure.write(key: 'user', value: jsonEncode(user!.toJson()));
      } catch (_) {/* retried next launch; UI already switched */}
    }
  }

  Future<void> setRoleIntent(String role) async {
    roleIntent = role;
    await _prefs.setString('roleIntent', role);
    notifyListeners();
  }

  Future<void> signIn(AuthResult r) async {
    token = r.token;
    user = r.user;
    api.token = token;
    await _secure.write(key: 'token', value: token);
    await _secure.write(key: 'user', value: jsonEncode(user!.toJson()));
    notifyListeners();
  }

  Future<void> signOut() async {
    token = null;
    user = null;
    api.token = null;
    await _secure.delete(key: 'token');
    await _secure.delete(key: 'user');
    notifyListeners();
  }
}
