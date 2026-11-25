import 'package:dio/dio.dart';

import 'config.dart';
import 'demo_api.dart';

typedef Json = Map<String, dynamic>;

class ApiException implements Exception {
  ApiException(this.code, this.message);
  final String code; // e.g. err.otp_invalid — message is already localised by the server
  final String message;
  bool get isNetwork => code == 'network';
  @override
  String toString() => message;
}

class SessionUser {
  SessionUser({required this.id, required this.phone, required this.role, required this.language, this.name, this.kycLevel = 0});
  final String id, phone, role, language;
  final String? name;
  final int kycLevel;

  factory SessionUser.fromJson(Json j) => SessionUser(
        id: j['id'] as String,
        phone: j['phone'] as String,
        role: j['role'] as String,
        language: j['language_code'] as String,
        name: j['name'] as String?,
        kycLevel: (j['kyc_level'] as num?)?.toInt() ?? 0,
      );
  Json toJson() => {'id': id, 'phone': phone, 'role': role, 'language_code': language, 'name': name, 'kyc_level': kycLevel};
}

class AuthResult {
  AuthResult(this.token, this.user, this.homeRoute);
  final String token;
  final SessionUser user;
  final String homeRoute;
}

/// One interface for the whole app. [HttpApi] talks to the FastAPI backend; [DemoApi] is a
/// complete on-device simulation (same JSON shapes, same rules) so the APK is fully usable
/// before the backend is deployed. Screens never know which one they are using.
abstract class Api {
  set token(String? t);
  set language(String lang);

  // auth
  Future<void> requestOtp(String phone, String lang);
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang});
  Future<SessionUser> setLanguage(String lang);

  // worker
  Future<List<Json>> workerFeed();
  Future<Json> workerJob(String id);
  Future<Json> placeBid(String jobId, int priceInr, String clientRef);
  Future<List<Json>> myBids();
  Future<void> withdrawBid(String bidId);
  Future<List<Json>> assignments();
  Future<void> startWork(String assignmentId);
  Future<Json> attendance(Json body);
  Future<void> rateCustomer(String assignmentId, int clarity, int timelyPayment, String? comment);
  /// "I'm on my way" → customer sees live distance + ETA. Then position updates while travelling.
  Future<void> startJourney(String assignmentId, double? lat, double? lng);
  Future<void> sendLocation(String assignmentId, double lat, double lng);
  /// Worker says the work is finished (customer confirms + rates).
  Future<void> markDone(String assignmentId);
  Future<Json> earnings();
  Future<Json> withdraw();
  Future<Json> workerProfile();
  Future<Json> labourCard();
  Future<void> kycLevel1({required String name, required String upi, String? selfieKey, List<String>? trades});
  Future<void> kycLevel2(String docType, String docKey);
  Future<void> setOnline(bool online);
  /// Worker's current position → feed distances + "jobs near you". (Demo: also moves the
  /// sample jobs to the user's real area so maps, distances and check-in work anywhere.)
  Future<void> updateMyLocation(double lat, double lng);

  // customer
  Future<List<Json>> customerJobs();
  Future<Json> priceEstimate(List<String> trades, String? locality);
  Future<Json> createJob(Json body);
  Future<Json> customerJob(String id);
  Future<Json> acceptBid(String jobId, String bidId);
  /// Payment page: quote + fee into escrow. Returns the payment (with method, paid_at, ref).
  Future<Json> payJob(String jobId, String method);
  Future<void> completeJob(String jobId);
  Future<Json> rateWorker(String jobId, Json stars);
  Future<void> cancelJob(String jobId);
  Future<void> dispute(String jobId, String reason);
  Future<List<Json>> payments();
  Future<List<Json>> browseWorkers(String? trade);
  Future<Json> workerPublic(String workerId);

  // shared
  Future<Json> upload(String kind, String filePath);
  Future<String> transcribe(String key, String lang);
  Future<List<Json>> chat(String jobId, String withUser);
  Future<void> sendChat(String jobId, String to, String body);
  /// Inbox for both roles, newest first: `{job_id, with_user, with_name, trades, locality,
  /// last_body, last_at, unread}`. Opening a thread via [chat] marks it read.
  Future<List<Json>> chatThreads();
  Future<String> voiceQuery(String text);
  Future<String> supportTicket(String subject, String? transcript);

  static Api create() => AppConfig.isDemo ? DemoApi() : HttpApi(AppConfig.apiBaseUrl);
}

class HttpApi implements Api {
  HttpApi(String baseUrl)
      : _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 30)));
  final Dio _dio;
  String? _token;
  String _lang = 'hi';

  @override
  set token(String? t) => _token = t;
  @override
  set language(String lang) => _lang = lang;

  Options get _o => Options(headers: {
        if (_token != null) 'Authorization': 'Bearer $_token',
        'Accept-Language': _lang, // server localises every error into this language
      });

  Future<dynamic> _wrap(Future<Response<dynamic>> Function() fn) async {
    try {
      return (await fn()).data;
    } on DioException catch (e) {
      final data = e.response?.data;
      final err = data is Map ? data['error'] as Map? : null;
      if (err != null) throw ApiException(err['code'] as String, err['message'] as String);
      throw ApiException('network', '');
    }
  }

  Future<dynamic> _get(String p, [Map<String, dynamic>? q]) => _wrap(() => _dio.get(p, queryParameters: q, options: _o));
  Future<dynamic> _post(String p, [Object? body]) => _wrap(() => _dio.post(p, data: body, options: _o));
  Future<dynamic> _patch(String p, Object body) => _wrap(() => _dio.patch(p, data: body, options: _o));
  List<Json> _list(dynamic d) => [for (final x in d as List) Map<String, dynamic>.from(x as Map)];
  Json _map(dynamic d) => Map<String, dynamic>.from(d as Map);

  @override
  Future<void> requestOtp(String phone, String lang) async {
    _lang = lang;
    await _post('/auth/otp/request', {'phone': phone, 'language_code': lang});
  }

  @override
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang}) async {
    _lang = lang;
    final j = _map(await _post('/auth/otp/verify', {'phone': phone, 'code': code, 'role': role, 'language_code': lang}));
    return AuthResult(j['token'] as String, SessionUser.fromJson(_map(j['user'])), j['home_route'] as String);
  }

  @override
  Future<SessionUser> setLanguage(String lang) async {
    _lang = lang;
    return SessionUser.fromJson(_map(await _patch('/me', {'language_code': lang})));
  }

  @override
  Future<List<Json>> workerFeed() async => _list(await _get('/worker/feed'));
  @override
  Future<Json> workerJob(String id) async => _map(await _get('/worker/jobs/$id'));
  @override
  Future<Json> placeBid(String jobId, int priceInr, String clientRef) async =>
      _map(await _post('/worker/bids', {'job_id': jobId, 'price_inr': priceInr, 'client_ref': clientRef}));
  @override
  Future<List<Json>> myBids() async => _list(await _get('/worker/bids'));
  @override
  Future<void> withdrawBid(String bidId) => _post('/worker/bids/$bidId/withdraw');
  @override
  Future<List<Json>> assignments() async => _list(await _get('/worker/assignments'));
  @override
  Future<void> startWork(String assignmentId) => _post('/worker/assignments/$assignmentId/start');
  @override
  Future<Json> attendance(Json body) async => _map(await _post('/worker/attendance', body));
  @override
  Future<void> rateCustomer(String assignmentId, int clarity, int timelyPayment, String? comment) =>
      _post('/worker/assignments/$assignmentId/rate-customer', {'clarity': clarity, 'timely_payment': timelyPayment, 'comment': comment});
  @override
  Future<void> startJourney(String assignmentId, double? lat, double? lng) =>
      _post('/worker/assignments/$assignmentId/journey', {'lat': lat, 'lng': lng});
  @override
  Future<void> sendLocation(String assignmentId, double lat, double lng) =>
      _post('/worker/assignments/$assignmentId/location', {'lat': lat, 'lng': lng});
  @override
  Future<void> markDone(String assignmentId) => _post('/worker/assignments/$assignmentId/done');
  @override
  Future<Json> earnings() async => _map(await _get('/worker/earnings'));
  @override
  Future<Json> withdraw() async => _map(await _post('/worker/withdraw'));
  @override
  Future<Json> workerProfile() async => _map(await _get('/worker/profile'));
  @override
  Future<Json> labourCard() async => _map(await _get('/worker/labour-card'));
  @override
  Future<void> kycLevel1({required String name, required String upi, String? selfieKey, List<String>? trades}) =>
      _post('/worker/kyc/level1', {'name': name, 'upi_id': upi, 'selfie_key': selfieKey, 'trades': trades});
  @override
  Future<void> kycLevel2(String docType, String docKey) => _post('/worker/kyc/level2', {'doc_type': docType, 'doc_key': docKey});
  @override
  Future<void> setOnline(bool online) => _patch('/worker/profile', {'is_online': online});
  @override
  Future<void> updateMyLocation(double lat, double lng) => _patch('/worker/profile', {'home_lat': lat, 'home_lng': lng});

  @override
  Future<List<Json>> customerJobs() async => _list(await _get('/customer/jobs'));
  @override
  Future<Json> priceEstimate(List<String> trades, String? locality) async =>
      _map(await _get('/customer/price-estimate', {'trades': trades.join(','), if (locality != null) 'locality': locality}));
  @override
  Future<Json> createJob(Json body) async => _map(await _post('/customer/jobs', body));
  @override
  Future<Json> customerJob(String id) async => _map(await _get('/customer/jobs/$id'));
  @override
  Future<Json> acceptBid(String jobId, String bidId) async => _map(await _post('/customer/jobs/$jobId/bids/$bidId/accept'));
  @override
  Future<Json> payJob(String jobId, String method) async => _map(await _post('/customer/jobs/$jobId/pay', {'method': method}));
  @override
  Future<void> completeJob(String jobId) => _post('/customer/jobs/$jobId/complete');
  @override
  Future<Json> rateWorker(String jobId, Json stars) async => _map(await _post('/customer/jobs/$jobId/rate', stars));
  @override
  Future<void> cancelJob(String jobId) => _post('/customer/jobs/$jobId/cancel');
  @override
  Future<void> dispute(String jobId, String reason) => _post('/customer/jobs/$jobId/dispute', {'reason': reason});
  @override
  Future<List<Json>> payments() async => _list(await _get('/customer/payments'));
  @override
  Future<List<Json>> browseWorkers(String? trade) async => _list(await _get('/customer/workers', {if (trade != null) 'trade': trade}));
  @override
  Future<Json> workerPublic(String workerId) async => _map(await _get('/customer/workers/$workerId'));

  @override
  Future<Json> upload(String kind, String filePath) async => _map(await _wrap(() => _dio.post('/media/upload',
      data: FormData.fromMap({'kind': kind, 'file': MultipartFile.fromFileSync(filePath, filename: filePath.split('/').last)}),
      options: _o)));
  @override
  Future<String> transcribe(String key, String lang) async =>
      (_map(await _post('/media/transcribe', {'key': key, 'lang': lang})))['transcript'] as String;
  @override
  Future<List<Json>> chat(String jobId, String withUser) async => _list(await _get('/jobs/$jobId/chat', {'with': withUser}));
  @override
  Future<void> sendChat(String jobId, String to, String body) => _post('/jobs/$jobId/chat', {'to': to, 'body': body});
  @override
  Future<List<Json>> chatThreads() async => _list(await _get('/chats'));
  @override
  Future<String> voiceQuery(String text) async => (_map(await _post('/voice/query', {'text': text})))['answer'] as String;
  @override
  Future<String> supportTicket(String subject, String? transcript) async =>
      (_map(await _post('/support/tickets', {'subject': subject, 'transcript': transcript, 'channel': 'app'})))['reply'] as String;
}
