import 'package:dio/dio.dart';

import 'config.dart';

class ApiException implements Exception {
  ApiException(this.code, this.message);
  final String code; // e.g. err.otp_invalid — message is already localised by the server
  final String message;
  @override
  String toString() => message;
}

class SessionUser {
  SessionUser({required this.id, required this.phone, required this.role, required this.language, this.name, this.kycLevel = 0});
  final String id, phone, role, language;
  final String? name;
  final int kycLevel;

  factory SessionUser.fromJson(Map<String, dynamic> j) => SessionUser(
        id: j['id'] as String,
        phone: j['phone'] as String,
        role: j['role'] as String,
        language: j['language_code'] as String,
        name: j['name'] as String?,
        kycLevel: (j['kyc_level'] as num?)?.toInt() ?? 0,
      );
  Map<String, dynamic> toJson() =>
      {'id': id, 'phone': phone, 'role': role, 'language_code': language, 'name': name, 'kyc_level': kycLevel};
}

class AuthResult {
  AuthResult(this.token, this.user, this.homeRoute);
  final String token;
  final SessionUser user;
  final String homeRoute;
}

class FeedJob {
  FeedJob(this.id, this.locality, this.trades, this.thumbnails, this.audioSeconds, this.audioKb, this.workCount,
      this.distanceKm, this.postedAt, this.alreadyBid);
  final String id, locality;
  final List<String> trades, thumbnails;
  final int? audioSeconds, audioKb;
  final int workCount;
  final double? distanceKm;
  final DateTime postedAt;
  final bool alreadyBid;

  factory FeedJob.fromJson(Map<String, dynamic> j) {
    final audio = j['audio'] as Map<String, dynamic>?;
    return FeedJob(
      j['id'] as String,
      j['locality'] as String,
      [for (final t in j['trades'] as List) (t as Map)['code'] as String],
      [for (final u in j['thumbnails'] as List) u as String],
      (audio?['total_seconds'] as num?)?.toInt(),
      (audio?['total_kb'] as num?)?.toInt(),
      (j['work_count'] as num).toInt(),
      (j['distance_km'] as num?)?.toDouble(),
      DateTime.parse(j['posted_at'] as String),
      j['already_bid'] as bool? ?? false,
    );
  }
}

class CustomerJob {
  CustomerJob(this.id, this.status, this.locality, this.bidCount, this.trades);
  final String id, status, locality;
  final int bidCount;
  final List<String> trades;
  factory CustomerJob.fromJson(Map<String, dynamic> j) => CustomerJob(j['id'] as String, j['status'] as String,
      j['locality'] as String, (j['bid_count'] as num).toInt(), [for (final t in j['trades'] as List) t as String]);
}

/// The app talks to this interface only; [HttpApi] for a real backend, [DemoApi] otherwise.
abstract class Api {
  Future<void> requestOtp(String phone, String lang);
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang});
  Future<SessionUser> setLanguage(String lang);
  Future<List<FeedJob>> workerFeed();
  Future<List<CustomerJob>> customerJobs();
  set token(String? t);

  static Api create() => AppConfig.isDemo ? DemoApi() : HttpApi(AppConfig.apiBaseUrl);
}

class HttpApi implements Api {
  HttpApi(String baseUrl)
      : _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 20)));
  final Dio _dio;
  String? _token;
  String _lang = 'hi';

  @override
  set token(String? t) => _token = t;

  Future<dynamic> _call(Future<Response<dynamic>> Function(Options o) fn) async {
    final o = Options(headers: {
      if (_token != null) 'Authorization': 'Bearer $_token',
      'Accept-Language': _lang, // server localises every error to this
    });
    try {
      return (await fn(o)).data;
    } on DioException catch (e) {
      final err = (e.response?.data is Map) ? (e.response!.data as Map)['error'] as Map? : null;
      if (err != null) throw ApiException(err['code'] as String, err['message'] as String);
      throw ApiException('network', '');
    }
  }

  @override
  Future<void> requestOtp(String phone, String lang) async {
    _lang = lang;
    await _call((o) => _dio.post('/auth/otp/request', data: {'phone': phone, 'language_code': lang}, options: o));
  }

  @override
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang}) async {
    _lang = lang;
    final j = await _call((o) => _dio.post('/auth/otp/verify',
        data: {'phone': phone, 'code': code, 'role': role, 'language_code': lang}, options: o)) as Map<String, dynamic>;
    return AuthResult(j['token'] as String, SessionUser.fromJson(j['user'] as Map<String, dynamic>), j['home_route'] as String);
  }

  @override
  Future<SessionUser> setLanguage(String lang) async {
    _lang = lang;
    final j = await _call((o) => _dio.patch('/me', data: {'language_code': lang}, options: o));
    return SessionUser.fromJson(j as Map<String, dynamic>);
  }

  @override
  Future<List<FeedJob>> workerFeed() async =>
      [for (final j in await _call((o) => _dio.get('/worker/feed', options: o)) as List) FeedJob.fromJson(j as Map<String, dynamic>)];

  @override
  Future<List<CustomerJob>> customerJobs() async => [
        for (final j in await _call((o) => _dio.get('/customer/jobs', options: o)) as List)
          CustomerJob.fromJson(j as Map<String, dynamic>)
      ];
}

/// In-memory stand-in for the backend, mirroring backend/app/seed.py.
/// Same phone numbers, same rules (OTP 123456, admins can't use the mobile app).
class DemoApi implements Api {
  @override
  set token(String? t) {}

  static const _names = {
    '9100000001': ('Priya Sharma', 'customer'),
    '9100000002': ('Anil Deshmukh', 'customer'),
    '9100000003': ('Neha Kulkarni', 'customer'),
    '9000000001': ('Ops Admin', 'admin'),
    '9200000001': ('Ramesh Pawar', 'worker'),
    '9200000003': ('Imran Shaikh', 'worker'),
    '9200000005': ('Venkat Rao', 'worker'),
  };

  Future<void> _lag() => Future.delayed(const Duration(milliseconds: 450));

  @override
  Future<void> requestOtp(String phone, String lang) => _lag();

  @override
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang}) async {
    await _lag();
    if (code != '123456') throw ApiException('err.otp_invalid', '');
    final known = _names[phone];
    final r = known?.$2 ?? (phone.startsWith('91') ? 'customer' : (role ?? 'worker'));
    return AuthResult('demo-token', SessionUser(id: 'demo-$phone', phone: phone, role: r, language: lang, name: known?.$1, kycLevel: known == null ? 0 : 1),
        r == 'worker' ? '/worker/jobs' : r == 'customer' ? '/customer/home' : '/admin');
  }

  @override
  Future<SessionUser> setLanguage(String lang) async => throw UnimplementedError(); // AppState handles demo locally

  @override
  Future<List<FeedJob>> workerFeed() async {
    await _lag();
    final now = DateTime.now();
    String p(String s) => 'https://picsum.photos/seed/bc-$s/400/300';
    return [
      FeedJob('d1', 'Kothrud', ['plumber', 'mason'], [p('j1w0p0'), p('j1w0p1'), p('j1w1p0')], 24, 18, 2, 1.8,
          now.subtract(const Duration(minutes: 40)), false),
      FeedJob('d2', 'Baner', ['electrician', 'painter', 'helper'], [p('j2w0p0'), p('j2w1p0')], 37, 18, 3, 4.6,
          now.subtract(const Duration(hours: 5)), false),
      FeedJob('d3', 'Aundh', ['carpenter'], [p('j3w0p0')], null, null, 1, 6.2, now.subtract(const Duration(days: 1)), true),
    ];
  }

  @override
  Future<List<CustomerJob>> customerJobs() async {
    await _lag();
    return [
      CustomerJob('c1', 'bidding', 'Baner', 3, ['electrician', 'painter', 'helper']),
      CustomerJob('c2', 'completed', 'Kothrud', 2, ['painter', 'painter']),
      CustomerJob('c3', 'open', 'Kothrud', 0, ['plumber', 'mason']),
    ];
  }
}
