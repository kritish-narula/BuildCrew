import 'package:dio/dio.dart';

import 'config.dart';
import 'demo_api.dart';

typedef Json = Map<String, dynamic>;

/// Hinglish (`en_IN`) is a UI-only language. The server has no Roman-Hindi text, so every API
/// call sends `hi` instead (descriptions are translated to Hindi server-side).
String wireLang(String code) => code == 'en_IN' ? 'hi' : code;

class ApiException implements Exception {
  ApiException(this.code, this.message);
  final String code; // e.g. err.otp_invalid — message is already localised by the server
  final String message;
  bool get isNetwork => code == 'network';
  @override
  String toString() => message;
}

class SessionUser {
  SessionUser({required this.id, required this.phone, required this.role, required this.language, this.name, this.kycLevel = 0,
      this.customerType, this.orgName});
  final String id, phone, role, language;
  final String? name;
  final int kycLevel;
  /// Customers only: `homeowner` or `contractor` (a contractor hires whole teams and sees the Team tab).
  final String? customerType;
  final String? orgName;
  bool get isContractor => role == 'customer' && customerType == 'contractor';

  factory SessionUser.fromJson(Json j) => SessionUser(
        id: j['id'] as String,
        phone: j['phone'] as String,
        role: j['role'] as String,
        language: j['language_code'] as String,
        name: j['name'] as String?,
        kycLevel: (j['kyc_level'] as num?)?.toInt() ?? 0,
        customerType: j['customer_type'] as String?,
        orgName: j['org_name'] as String?,
      );
  Json toJson() => {'id': id, 'phone': phone, 'role': role, 'language_code': language, 'name': name, 'kyc_level': kycLevel,
        'customer_type': customerType, 'org_name': orgName};
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
  /// Start work needs the customer's 4-digit start code ([code]); wrong -> `err.start_code_invalid`, 5 misses -> `err.start_code_locked`.
  Future<void> startWork(String assignmentId, {String? code});
  Future<Json> attendance(Json body);
  Future<void> rateCustomer(String assignmentId, int clarity, int timelyPayment, String? comment);
  /// "I'm on my way" → customer sees live distance + ETA. Then position updates while travelling.
  Future<void> startJourney(String assignmentId, double? lat, double? lng);
  Future<void> sendLocation(String assignmentId, double lat, double lng);
  /// Worker says the work is finished. At least one "after" proof photo (a key from [upload]) is required;
  /// the customer then confirms, sends it back or reports a problem. Idempotent (safe to replay offline).
  Future<void> markDone(String assignmentId, {List<String> photos = const [], String? note});
  /// Worker: "customer is not confirming / unfair" → dispute, money stays in escrow.
  Future<void> workerDispute(String assignmentId, String reason);
  /// Worker can no longer do a job they were hired for (before starting): refund + job re-opens + strike if paid.
  Future<Json> withdrawHire(String assignmentId);
  /// `{..., paid_today: {total_inr, items: [{amount_inr, upi, state: processing|paid, at}]}, nudge_add_upi}`.
  Future<Json> earnings();
  Future<Json> withdraw();
  /// Optional police verification (admin decides): `{status: pending|verified|rejected}`.
  Future<Json> requestPoliceVerification();
  /// Push-style notices not shown yet: `[{id, kind: payout_sent, amount_inr, upi, state}]`; call [ackNotices] once shown.
  Future<List<Json>> workerNotices();
  Future<void> ackNotices(List<String> ids);
  /// Decline a "hire again" request: the job opens to everyone.
  Future<void> declineDirect(String jobId);
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
  Future<Json> priceEstimate(List<String> trades, String? locality, {List<String?>? texts, String? city});
  Future<Json> createJob(Json body);
  Future<Json> customerJob(String id);
  Future<Json> acceptBid(String jobId, String bidId);
  /// Payment page: quote + fee into escrow. Returns the payment (with method, paid_at, ref).
  Future<Json> payJob(String jobId, String method);
  Future<void> completeJob(String jobId);
  Future<Json> rateWorker(String jobId, Json stars);
  /// Cancel: free before a hire; after a hire (work not started) the hire ends and paid money is refunded in
  /// full (`refunded_inr`). After work started → throws `err.job_started_dispute`. Idempotent.
  Future<Json> cancelJob(String jobId);
  /// "Not done yet — send back". [reasons]: incomplete | poor_quality | damage | not_came | other. Rounds 1-2 return
  /// `{outcome: rework, rework_count, rework_left}`; the 3rd disagreement opens a dispute (`outcome: disputed`).
  Future<Json> sendBack(String jobId, {required List<String> reasons, String? note, List<String> photos = const []});
  /// "Choose another worker": ends the hire (refund if paid) and re-opens the job; earlier quotes return.
  Future<Json> reopenJob(String jobId);
  /// "Worker never arrived": allowed 60 min after the ETA. Refund if paid, job re-opens.
  Future<Json> reportNoShow(String jobId);
  /// No quotes yet: remind nearby workers (once per 6 h → `err.nudge_too_soon`).
  Future<void> nudgeJob(String jobId);
  Future<void> dispute(String jobId, String reason);
  /// DEMO ONLY: pretend [by] has passed for this job (timers: 48 h auto-confirm, no-show ETA, support decision).
  /// The real backend throws `err.unsupported`.
  Future<void> demoSkipTime(String jobId, Duration by);
  Future<List<Json>> payments();
  Future<List<Json>> browseWorkers(String? trade);
  Future<Json> workerPublic(String workerId);
  /// "Your workers": `[{...worker summary, last_job_id, jobs_together, last_trade}]` (rated >= 4 by this customer).
  Future<List<Json>> favourites();
  /// Prefill for Post a Job: `{worker, items: [{trade, text_description, description_language}], address_text, lat, lng, city, locality}`.
  Future<Json> rebookDraft({String? jobId, String? workerId});
  /// "Share trip": `{token, url, worker_name, worker_phone_masked, trade, police_verified}` (only while the worker is on the way).
  Future<Json> shareTrip(String jobId);
  /// "Problem came back" inside the warranty window: free re-fix visit by the same worker. Returns `{job_id, assignment_id}`.
  Future<Json> requestRefix(String jobId, {required String reason, List<String> photos = const [], String? assignmentId});

  // contractor / team hiring
  /// Suggested daily wage per trade: `{items: [{trade, low, median, high, min_wage}]}` (low <= median <= high, low >= min wage).
  Future<Json> wageSuggestion(List<String> trades, String? city);
  /// Roster of a team job: `{summary, workers: [{assignment_id, worker, trade, daily_wage_inr, days_planned, days_worked,
  /// present_today, amount_due_inr, total_inr, payment, rated, settled}], payment_due_inr, payment_due_count}`.
  Future<Json> teamRoster(String jobId);
  /// Rate one team member (mandatory) -> pays the days worked, refunds the rest. Returns `{days_worked, payout_inr, refund_inr}`.
  Future<Json> settleTeamWorker(String jobId, String assignmentId, Json stars);
  /// Contractors: business name shown to workers.
  Future<void> setBusinessName(String name);

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
  set language(String lang) => _lang = wireLang(lang);

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
    _lang = wireLang(lang);
    await _post('/auth/otp/request', {'phone': phone, 'language_code': wireLang(lang)});
  }

  @override
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang}) async {
    _lang = wireLang(lang);
    final contractor = role == 'contractor'; // a customer account of type contractor
    final j = _map(await _post('/auth/otp/verify', {
      'phone': phone, 'code': code, 'role': contractor ? 'customer' : role, 'language_code': wireLang(lang),
      if (contractor) 'customer_type': 'contractor',
    }));
    return AuthResult(j['token'] as String, SessionUser.fromJson(_map(j['user'])), j['home_route'] as String);
  }

  @override
  Future<SessionUser> setLanguage(String lang) async {
    _lang = wireLang(lang);
    return SessionUser.fromJson(_map(await _patch('/me', {'language_code': wireLang(lang)})));
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
  Future<void> startWork(String assignmentId, {String? code}) => _post('/worker/assignments/$assignmentId/start', {'code': code});
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
  Future<void> markDone(String assignmentId, {List<String> photos = const [], String? note}) =>
      _post('/worker/assignments/$assignmentId/done', {'photos': photos, 'note': note});
  @override
  Future<void> workerDispute(String assignmentId, String reason) => _post('/worker/assignments/$assignmentId/dispute', {'reason': reason});
  @override
  Future<Json> withdrawHire(String assignmentId) async => _map(await _post('/worker/assignments/$assignmentId/withdraw'));
  @override
  Future<Json> earnings() async => _map(await _get('/worker/earnings'));
  @override
  Future<Json> withdraw() async => _map(await _post('/worker/withdraw'));
  @override
  Future<Json> requestPoliceVerification() async => _map(await _post('/worker/police-verification'));
  @override
  Future<List<Json>> workerNotices() async => _list(await _get('/worker/notices'));
  @override
  Future<void> ackNotices(List<String> ids) => _post('/worker/notices/ack', {'ids': ids});
  @override
  Future<void> declineDirect(String jobId) => _post('/worker/jobs/$jobId/decline');
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
  Future<Json> priceEstimate(List<String> trades, String? locality, {List<String?>? texts, String? city}) async =>
      _map(await _get('/customer/price-estimate', {
        'trades': trades.join(','),
        if (locality != null) 'locality': locality,
        if (city != null && city.isNotEmpty) 'city': city,
        if (texts != null) 'texts': texts.map((t) => (t ?? '').replaceAll('|', ' ')).join('|'),
      }));
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
  Future<Json> cancelJob(String jobId) async => _map(await _post('/customer/jobs/$jobId/cancel'));
  @override
  Future<Json> sendBack(String jobId, {required List<String> reasons, String? note, List<String> photos = const []}) async =>
      _map(await _post('/customer/jobs/$jobId/rework', {'reasons': reasons, 'note': note, 'photos': photos}));
  @override
  Future<Json> reopenJob(String jobId) async => _map(await _post('/customer/jobs/$jobId/reopen'));
  @override
  Future<Json> reportNoShow(String jobId) async => _map(await _post('/customer/jobs/$jobId/no-show'));
  @override
  Future<void> nudgeJob(String jobId) => _post('/customer/jobs/$jobId/nudge');
  @override
  Future<void> demoSkipTime(String jobId, Duration by) async => throw ApiException('err.unsupported', '');
  @override
  Future<void> dispute(String jobId, String reason) => _post('/customer/jobs/$jobId/dispute', {'reason': reason});
  @override
  Future<List<Json>> payments() async => _list(await _get('/customer/payments'));
  @override
  Future<List<Json>> browseWorkers(String? trade) async => _list(await _get('/customer/workers', {if (trade != null) 'trade': trade}));
  @override
  Future<Json> workerPublic(String workerId) async => _map(await _get('/customer/workers/$workerId'));
  @override
  Future<List<Json>> favourites() async => _list(await _get('/customer/favourites'));
  @override
  Future<Json> rebookDraft({String? jobId, String? workerId}) async =>
      _map(await _get(jobId != null ? '/customer/jobs/$jobId/rebook' : '/customer/workers/$workerId/rebook'));
  @override
  Future<Json> shareTrip(String jobId) async => _map(await _post('/customer/jobs/$jobId/share-trip'));
  @override
  Future<Json> requestRefix(String jobId, {required String reason, List<String> photos = const [], String? assignmentId}) async =>
      _map(await _post('/customer/jobs/$jobId/refix', {'reason': reason, 'photos': photos, if (assignmentId != null) 'assignment_id': assignmentId}));

  @override
  Future<Json> wageSuggestion(List<String> trades, String? city) async =>
      _map(await _get('/customer/wage-suggestion', {'trades': trades.join(','), if (city != null && city.isNotEmpty) 'city': city}));
  @override
  Future<Json> teamRoster(String jobId) async => _map(await _get('/customer/jobs/$jobId/team'));
  @override
  Future<Json> settleTeamWorker(String jobId, String assignmentId, Json stars) async =>
      _map(await _post('/customer/jobs/$jobId/team/$assignmentId/settle', stars));
  @override
  Future<void> setBusinessName(String name) => _patch('/me', {'business_name': name});

  @override
  Future<Json> upload(String kind, String filePath) async => _map(await _wrap(() => _dio.post('/media/upload',
      data: FormData.fromMap({'kind': kind, 'file': MultipartFile.fromFileSync(filePath, filename: filePath.split('/').last)}),
      options: _o)));
  @override
  Future<String> transcribe(String key, String lang) async =>
      (_map(await _post('/media/transcribe', {'key': key, 'lang': wireLang(lang)})))['transcript'] as String;
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
