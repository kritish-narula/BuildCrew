import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'location.dart';

/// On-device stand-in for the backend — same JSON shapes, same business rules:
///  * fees: quote + ₹30 flat, escrow HELD on accept
///  * MANDATORY RATING: payment can only be released by submitting the customer's rating
///  * bids and attendance are idempotent on client_ref (offline replay safe)
///  * progressive KYC: UPI needed only to withdraw
/// It also plays the *other side* of the marketplace so one person can try every flow:
/// workers quote on a newly posted job; a customer accepts the lowest quote after a while.
/// State is saved on the phone, so it survives restarts.
/// Real job photos (Unsplash License — free for commercial use, hot-linked from Unsplash's CDN
/// as their guidelines require). Sized for phones: 800 px, ~60–90 KB each.
String _u(String id) => 'https://images.unsplash.com/$id?w=800&q=65&auto=format&fit=crop';
final demoPhotos = <String, List<String>>{
  'tap_leak': [_u('photo-1697374981215-ce207e5ab8c0'), _u('photo-1720889589894-497c4f4f569e')],
  'plumber': [_u('photo-1749532125405-70950966b0e5'), _u('photo-1697374981215-ce207e5ab8c0')],
  'damp_wall': [_u('photo-1693594560514-258c66283f0d'), _u('photo-1693594560383-8292e83de622'), _u('photo-1768839725085-829e6ac7ac26')],
  'mason': [_u('photo-1704005445445-2747074be8ac'), _u('photo-1701850009190-2859ba2aeea6'), _u('photo-1673865641469-34498379d8af')],
  'electrician': [_u('photo-1751486289947-4f5f5961b3aa'), _u('photo-1621905251189-08b45d6a269e'), _u('photo-1635335874521-7987db781153')],
  'painter': [_u('photo-1717281234297-3def5ae3eee1'), _u('photo-1688372199140-cade7ae820fe'), _u('photo-1525909002-1b05e0c869d8')],
  'carpenter': [_u('photo-1779031242515-205111711b23'), _u('photo-1561297331-a9c00b9c2c44'), _u('photo-1544164560-adac3045edb2')],
  'helper': [_u('photo-1577199001468-44c049e7603f'), _u('photo-1632201147654-f6f54427e538')],
  'tiles': [_u('photo-1523413307857-ef24c53571ae'), _u('photo-1523350165414-082d792c4bcc')],
};

class DemoApi implements Api {
  DemoApi();

  static const _key = 'demo_db_v3';
  static const fee = 30;
  final _rnd = Random(7);
  Json? _db;
  String? _me;
  String _lang = 'hi';

  @override
  set token(String? t) => _me = (t != null && t.startsWith('demo:')) ? t.substring(5) : null;
  @override
  set language(String lang) => _lang = lang;

  // ---------------------------------------------------------------- storage
  Future<Json> get _d async {
    if (_db != null) return _db!;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    // Round-trip the seed through JSON so every list/map is a plain dynamic collection.
    // (BUG FIX: typed literals like List<Map<String,Object>> rejected rows containing null —
    // e.g. a check-in with no check-out yet — and showed "Something went wrong".)
    _db = jsonDecode(raw ?? jsonEncode(_seed())) as Json;
    return _db!;
  }

  /// Fresh sample data (Profile → Reset demo data).
  Future<void> reset() async {
    _db = null;
    await (await SharedPreferences.getInstance()).remove(_key);
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_db));
  Future<void> _lag() => Future.delayed(Duration(milliseconds: 250 + _rnd.nextInt(250)));
  String _id(String p) => '$p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(999)}';
  String _now() => DateTime.now().toIso8601String();
  Never _err(String code) => throw ApiException(code, '');

  Map<String, dynamic> _t(Json d, String table) => (d[table] as Map).cast<String, dynamic>();
  Json _row(Json d, String table, String id) => (_t(d, table)[id] as Map?)?.cast<String, dynamic>() ?? _err('err.not_found');
  Iterable<Json> _all(Json d, String table) => _t(d, table).values.map((e) => (e as Map).cast<String, dynamic>());
  Json _user(Json d, [String? id]) => _row(d, 'users', id ?? _me ?? _err('err.unauthorized'));

  // ---------------------------------------------------------------- views (match backend JSON)
  String? _text(Json item, String lang) {
    final t = (item['text'] as Map?)?.cast<String, dynamic>() ?? {};
    return (t[lang] ?? t[item['lang']] ?? (t.values.isEmpty ? null : t.values.first)) as String?;
  }

  Json _item(Json it, int i, String lang, {bool audio = true}) {
    final translated = lang != it['lang'] && ((it['text'] as Map?)?.containsKey(lang) ?? false);
    final tr = (it['transcript'] as Map?)?.cast<String, dynamic>();
    return {
      'id': it['id'], 'index': i + 1, 'trade': it['trade'], 'photos': it['photos'],
      'text': _text(it, lang), 'translated': translated, 'original_language': it['lang'],
      'transcript': tr == null ? null : (tr[lang] ?? tr[it['lang']] ?? tr.values.first),
      'audio': audio && it['audio'] != null && it['muted'] != true ? it['audio'] : null,
    };
  }

  Json _workerSummary(Json d, String id) {
    final u = _user(d, id);
    return {
      'id': id, 'name': u['name'] ?? 'Worker', 'trades': u['trades'], 'rating': u['rating'], 'rating_count': u['rating_count'],
      'completed_jobs': u['completed'], 'badges': u['badges'], 'kyc_level': u['kyc'], 'selfie': u['selfie'], 'verified': (u['kyc'] as int) >= 1,
    };
  }

  Json _jobCard(Json j) => {
        'id': j['id'], 'customer_id': j['customer_id'], 'status': j['status'], 'locality': j['locality'], 'city': 'Pune', 'address': j['address'],
        'lat': j['lat'], 'lng': j['lng'], 'start_date': j['start_date'], 'created_at': j['created_at'],
        'trades': [for (final it in j['items'] as List) (it as Map)['trade']],
        'thumbnail': [for (final it in j['items'] as List) ...((it as Map)['photos'] as List)].cast<String?>().firstOrNull,
      };

  Json? _assignmentFor(Json d, String jobId) => _all(d, 'assignments').where((a) => a['job_id'] == jobId).firstOrNull;
  Json? _paymentFor(Json d, String aid) => _all(d, 'payments').where((p) => p['assignment_id'] == aid).firstOrNull;

  Json _paymentView(Json p) => {
        'id': p['id'], 'amount_inr': p['amount'], 'platform_fee_inr': p['fee'], 'worker_payout_inr': p['payout'],
        'refund_inr': p['refund'] ?? 0, 'escrow_state': p['state'], 'released_at': p['released_at'], 'ref': 'BC-${(p['id'] as String).toUpperCase()}',
        'method': p['method'], 'paid_at': p['paid_at'],
      };

  Json _assignmentView(Json d, Json a) {
    final p = _paymentFor(d, a['id'] as String);
    final ratings = <String, dynamic>{
      for (final r in (d['ratings'] as List).cast<Map>().where((r) => r['assignment_id'] == a['id'])) r['direction'] as String: r,
    };
    final bid = _row(d, 'bids', a['bid_id'] as String);
    return {
      'tracking': _tracking(d, a), 'worker_done_at': a['worker_done_at'],
      'id': a['id'], 'worker': _workerSummary(d, a['worker_id'] as String), 'price_inr': bid['price'],
      'started_at': a['started_at'], 'completed_at': a['completed_at'], 'payment': p == null ? null : _paymentView(p),
      'ratings': ratings,
      'attendance': [
        for (final x in (d['attendance'] as List).cast<Map>().where((x) => x['assignment_id'] == a['id']))
          {'in': x['in'], 'out': x['out'], 'offline': x['offline'], 'geofence_ok': x['geofence_ok'], 'selfie': x['selfie']}
      ],
    };
  }

  // ---------------------------------------------------------------- live tracking (demo)
  /// Demo travel is compressed to 2 minutes so a presentation doesn't wait; the ETA shown is
  /// still the realistic one (distance at 20 km/h), and it counts down as the marker moves.
  static const _demoTravelSeconds = 120;

  Json? _tracking(Json d, Json a) {
    final started = a['journey_started_at'] as String?;
    if (started == null) return null;
    final j = _row(d, 'jobs', a['job_id'] as String);
    final from = (a['journey_from'] as Map?) ?? {'lat': j['lat'], 'lng': j['lng']};
    final p = (DateTime.now().difference(DateTime.parse(started)).inMilliseconds / (_demoTravelSeconds * 1000)).clamp(0.0, 1.0);
    final lat = (from['lat'] as num) + ((j['lat'] as num) - (from['lat'] as num)) * p;
    final lng = (from['lng'] as num) + ((j['lng'] as num) - (from['lng'] as num)) * p;
    final km = _dist({'lat': lat, 'lng': lng}, j);
    final arrived = a['started_at'] != null || km <= 0.15;
    return {'journey_started_at': started, 'worker_lat': lat, 'worker_lng': lng, 'updated_at': _now(),
      'distance_km': double.parse(km.toStringAsFixed(2)), 'eta_min': arrived ? 0 : max(1, (km / 20 * 60).round()), 'arrived': arrived};
  }

  /// Start the worker ~3 km from the house (or from the phone's real position if it is far).
  void _beginJourney(Json d, Json a, {double? lat, double? lng}) {
    final j = _row(d, 'jobs', a['job_id'] as String);
    Map<String, dynamic> from;
    if (lat != null && lng != null && _dist({'lat': lat, 'lng': lng}, j) > 0.5) {
      from = {'lat': lat, 'lng': lng};
    } else {
      from = {'lat': (j['lat'] as num) + 0.021, 'lng': (j['lng'] as num) - 0.014}; // ≈ 2.8 km away
    }
    a['journey_from'] = from;
    a['journey_started_at'] = _now();
  }

  double _dist(Json u, Json j) {
    double r(double v) => v * pi / 180;
    final la1 = r((u['lat'] as num).toDouble()), la2 = r((j['lat'] as num).toDouble());
    final dl = r((j['lng'] as num).toDouble() - (u['lng'] as num).toDouble());
    final h = pow(sin((la2 - la1) / 2), 2) + cos(la1) * cos(la2) * pow(sin(dl / 2), 2);
    return 2 * 6371 * asin(sqrt(h));
  }

  // ---------------------------------------------------------------- marketplace simulation
  /// Workers quote on a customer's new job ~15 s after posting; a customer accepts a worker's
  /// lowest pending quote ~30 s after it was placed. Lazy: evaluated whenever data is read.
  void _simulate(Json d) {
    final now = DateTime.now();
    for (final j in _all(d, 'jobs').toList()) {
      if (!(j['status'] == 'open' || j['status'] == 'bidding') || j['sim'] != true) continue;
      if (now.difference(DateTime.parse(j['created_at'] as String)).inSeconds < 15) continue;
      final trades = {for (final it in j['items'] as List) (it as Map)['trade']};
      final have = _all(d, 'bids').where((b) => b['job_id'] == j['id']).length;
      if (have > 0) continue;
      final pool = _all(d, 'users').where((u) => u['role'] == 'worker' && (u['trades'] as List).any(trades.contains)).take(3).toList();
      final base = 600 * (j['items'] as List).length + 400;
      for (final w in pool) {
        final id = _id('b');
        _t(d, 'bids')[id] = {'id': id, 'job_id': j['id'], 'worker_id': w['id'], 'price': base + _rnd.nextInt(12) * 100, 'status': 'pending', 'created_at': _now()};
      }
      if (pool.isNotEmpty) j['status'] = 'bidding';
    }
    // customer side: accept a worker's quote placed from this phone
    for (final b in _all(d, 'bids').where((b) => b['status'] == 'pending' && b['sim_accept'] == true).toList()) {
      if (now.difference(DateTime.parse(b['created_at'] as String)).inSeconds < 30) continue;
      final job = _row(d, 'jobs', b['job_id'] as String);
      if (job['status'] != 'bidding') continue;
      _doAccept(d, job, b, paid: true);
    }
  }

  void _doAccept(Json d, Json job, Json bid, {bool paid = false}) {
    job['status'] = 'assigned';
    for (final o in _all(d, 'bids').where((x) => x['job_id'] == job['id'] && x['status'] == 'pending')) {
      o['status'] = identical(o, bid) || o['id'] == bid['id'] ? 'accepted' : 'rejected';
    }
    bid['status'] = 'accepted';
    final aid = _id('a');
    _t(d, 'assignments')[aid] = {'id': aid, 'job_id': job['id'], 'worker_id': bid['worker_id'], 'bid_id': bid['id']};
    final pid = _id('p');
    final price = bid['price'] as num;
    // Escrow waits for the customer's payment page unless this is the simulated customer.
    _t(d, 'payments')[pid] = {'id': pid, 'assignment_id': aid, 'amount': price + fee, 'fee': fee, 'payout': price,
      'state': paid ? 'held' : 'created', if (paid) 'method': 'upi', if (paid) 'paid_at': _now()};
  }

  void _requirePaid(Json d, Json a) {
    if (_paymentFor(d, a['id'] as String)?['state'] == 'created') _err('err.payment_pending');
  }

  // ---------------------------------------------------------------- auth
  @override
  Future<void> requestOtp(String phone, String lang) => _lag();

  @override
  Future<AuthResult> verifyOtp(String phone, String code, {String? role, required String lang}) async {
    await _lag();
    if (code != '123456') _err('err.otp_invalid');
    final d = await _d;
    var u = _all(d, 'users').where((u) => u['phone'] == phone).firstOrNull;
    if (u == null) {
      final r = role == 'customer' ? 'customer' : 'worker';
      final id = _id(r[0]);
      u = {'id': id, 'phone': phone, 'role': r, 'name': null, 'lang': lang, 'kyc': 0, 'trades': <String>[], 'rating': 0.0,
        'rating_count': 0, 'completed': 0, 'badges': <String>[], 'lat': 18.52, 'lng': 73.85, 'online': true, 'earned': 0};
      _t(d, 'users')[id] = u;
      await _save();
    }
    _me = u['id'] as String;
    final user = SessionUser(id: _me!, phone: phone, role: u['role'] as String, language: lang, name: u['name'] as String?, kycLevel: u['kyc'] as int);
    return AuthResult('demo:$_me', user, '/${user.role}');
  }

  @override
  Future<SessionUser> setLanguage(String lang) async {
    final d = await _d;
    final u = _user(d)..['lang'] = lang;
    await _save();
    return SessionUser(id: u['id'] as String, phone: u['phone'] as String, role: u['role'] as String, language: lang,
        name: u['name'] as String?, kycLevel: u['kyc'] as int);
  }

  // ---------------------------------------------------------------- worker
  @override
  Future<List<Json>> workerFeed() async {
    await _lag();
    final d = await _d;
    _simulate(d);
    final me = _user(d);
    final my = {for (final b in _all(d, 'bids').where((b) => b['worker_id'] == _me)) b['job_id']: b};
    final out = <Json>[];
    final jobs = _all(d, 'jobs').where((j) => j['status'] == 'open' || j['status'] == 'bidding').toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    for (final j in jobs) {
      final trades = [for (final it in j['items'] as List) (it as Map)['trade'] as String];
      if ((me['trades'] as List).isNotEmpty && !trades.any((t) => (me['trades'] as List).contains(t))) continue;
      final audio = [for (final it in j['items'] as List) if ((it as Map)['audio'] != null && it['muted'] != true) it['audio'] as Map];
      final mine = my[j['id']];
      out.add({
        'id': j['id'], 'locality': j['locality'], 'trades': [for (final t in trades.toSet()) {'code': t}],
        'thumbnails': [for (final it in j['items'] as List) ...((it as Map)['photos'] as List)].take(4).toList(),
        'audio': audio.isEmpty ? null : {'count': audio.length, 'total_seconds': audio.fold<int>(0, (s, a) => s + (a['duration_sec'] as int)),
          'total_kb': audio.fold<int>(0, (s, a) => s + (a['size_kb'] as int))},
        'work_count': (j['items'] as List).length, 'distance_km': double.parse(_dist(me, j).toStringAsFixed(1)),
        'posted_at': j['created_at'], 'start_date': j['start_date'], 'already_bid': mine != null, 'my_price_inr': mine?['price'],
      });
    }
    await _save();
    return out;
  }

  @override
  Future<Json> workerJob(String id) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', id);
    final me = _user(d);
    final mine = _all(d, 'bids').where((b) => b['job_id'] == id && b['worker_id'] == _me).firstOrNull;
    final items = j['items'] as List;
    return {
      ..._jobCard(j), 'address': mine?['status'] == 'accepted' ? j['address'] : j['locality'],
      'distance_km': double.parse(_dist(me, j).toStringAsFixed(1)),
      'work_items': [for (var i = 0; i < items.length; i++) _item((items[i] as Map).cast<String, dynamic>(), i, _lang)],
      'my_bid': mine == null ? null : {'id': mine['id'], 'price_inr': mine['price'], 'status': mine['status']},
      'bid_count': _all(d, 'bids').where((b) => b['job_id'] == id).length,
    };
  }

  @override
  Future<Json> placeBid(String jobId, int priceInr, String clientRef) async {
    await _lag();
    final d = await _d;
    final dup = _all(d, 'bids').where((b) => b['client_ref'] == clientRef).firstOrNull;
    if (dup != null) return {'id': dup['id'], 'status': dup['status'], 'price_inr': dup['price']};
    final j = _row(d, 'jobs', jobId);
    if (!(j['status'] == 'open' || j['status'] == 'bidding')) _err('err.job_closed');
    if (priceInr < 100) _err('err.validation');
    var b = _all(d, 'bids').where((b) => b['job_id'] == jobId && b['worker_id'] == _me).firstOrNull;
    if (b != null && b['status'] == 'pending') {
      b['price'] = priceInr;
    } else if (b != null) {
      _err('err.bid_exists');
    } else {
      final id = _id('b');
      b = {'id': id, 'job_id': jobId, 'worker_id': _me, 'price': priceInr, 'status': 'pending', 'created_at': _now(),
        'client_ref': clientRef, 'sim_accept': j['sim_customer'] == true};
      _t(d, 'bids')[id] = b;
      j['status'] = 'bidding';
    }
    await _save();
    return {'id': b['id'], 'status': b['status'], 'price_inr': b['price']};
  }

  @override
  Future<List<Json>> myBids() async {
    await _lag();
    final d = await _d;
    _simulate(d);
    final out = <Json>[];
    final bids = _all(d, 'bids').where((b) => b['worker_id'] == _me).toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    for (final b in bids) {
      final a = _all(d, 'assignments').where((a) => a['bid_id'] == b['id']).firstOrNull;
      out.add({'id': b['id'], 'price_inr': b['price'], 'status': b['status'], 'created_at': b['created_at'],
        'job': _jobCard(_row(d, 'jobs', b['job_id'] as String)), 'assignment_id': a?['id']});
    }
    await _save();
    return out;
  }

  @override
  Future<void> withdrawBid(String bidId) async {
    final d = await _d;
    final b = _row(d, 'bids', bidId);
    if (b['status'] != 'pending') _err('err.job_closed');
    b['status'] = 'withdrawn';
    await _save();
  }

  @override
  Future<List<Json>> assignments() async {
    await _lag();
    final d = await _d;
    _simulate(d);
    return [
      for (final a in _all(d, 'assignments').where((a) => a['worker_id'] == _me))
        {
          ..._assignmentView(d, a),
          'job': {..._jobCard(_row(d, 'jobs', a['job_id'] as String)), 'address': _row(d, 'jobs', a['job_id'] as String)['address']},
          'customer_name': _user(d, _row(d, 'jobs', a['job_id'] as String)['customer_id'] as String)['name'],
        }
    ]..sort((x, y) => ((y['job'] as Json)['created_at'] as String).compareTo((x['job'] as Json)['created_at'] as String));
  }

  @override
  Future<void> startWork(String assignmentId) async {
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    _requirePaid(d, a);
    final j = _row(d, 'jobs', a['job_id'] as String);
    if (j['status'] == 'assigned') {
      j['status'] = 'in_progress';
      a['started_at'] = _now();
    }
    await _save();
  }

  @override
  Future<Json> attendance(Json body) async {
    await _lag();
    final d = await _d;
    final list = d['attendance'] as List;
    final dup = list.cast<Map>().where((x) => x['client_ref'] == body['client_ref']).firstOrNull;
    if (dup != null) return {'geofence_ok': dup['geofence_ok']};
    final a = _row(d, 'assignments', body['assignment_id'] as String);
    _requirePaid(d, a);
    final j = _row(d, 'jobs', a['job_id'] as String);
    final ok = _dist({'lat': body['lat'], 'lng': body['lng']}, j) * 1000 <= 300;
    if (body['kind'] == 'in') {
      list.add({'assignment_id': a['id'], 'in': body['at'] ?? _now(), 'out': null, 'offline': body['offline'] == true,
        'geofence_ok': ok, 'client_ref': body['client_ref'], 'selfie': body['selfie_key']});
      await startWork(a['id'] as String);
    } else {
      final open = list.cast<Map>().where((x) => x['assignment_id'] == a['id'] && x['out'] == null).lastOrNull;
      if (open == null) _err('err.not_checked_in');
      open['out'] = body['at'] ?? _now();
      open['geofence_ok'] = open['geofence_ok'] == true && ok;
    }
    await _save();
    return {'geofence_ok': ok};
  }

  @override
  Future<void> startJourney(String assignmentId, double? lat, double? lng) async {
    await _lag();
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    _requirePaid(d, a);
    _beginJourney(d, a, lat: lat, lng: lng);
    await _save();
  }

  @override
  Future<void> sendLocation(String assignmentId, double lat, double lng) async {} // demo moves the marker itself

  @override
  Future<void> markDone(String assignmentId) async {
    await _lag();
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    await startWork(assignmentId);
    a['worker_done_at'] = _now();
    await _save();
  }

  @override
  Future<void> rateCustomer(String assignmentId, int clarity, int timelyPayment, String? comment) async {
    final d = await _d;
    final rs = d['ratings'] as List;
    if (rs.cast<Map>().any((r) => r['assignment_id'] == assignmentId && r['direction'] == 'worker_to_customer')) _err('err.already_rated');
    rs.add({'assignment_id': assignmentId, 'direction': 'worker_to_customer', 'clarity': clarity, 'timely_payment': timelyPayment,
      'overall': (clarity + timelyPayment) / 2, 'comment': comment, 'created_at': _now()});
    await _save();
  }

  Json _balance(Json d, String wid) {
    num released = 0, held = 0;
    for (final a in _all(d, 'assignments').where((a) => a['worker_id'] == wid)) {
      final p = _paymentFor(d, a['id'] as String);
      if (p == null) continue;
      if (p['state'] == 'released' || p['state'] == 'split') released += p['payout'] as num;
      if (p['state'] == 'held') held += p['payout'] as num;
    }
    final paid = (d['payouts'] as List).cast<Map>().where((p) => p['worker_id'] == wid).fold<num>(0, (s, p) => s + (p['amount'] as num));
    return {'available': released - paid, 'held': held, 'paid': paid, 'released': released};
  }

  Json _kyc(Json u) {
    final earned = (u['earned'] as num?) ?? 0;
    return {'level': u['kyc'], 'needs_level1': (u['kyc'] as int) < 1, 'nudge_level2': (u['kyc'] as int) < 2 && earned >= 40000,
      'blocked_by_level2': (u['kyc'] as int) < 2 && earned >= 50000, 'doc_status': u['doc_status'] ?? 'not_submitted', 'note': null, 'cap_inr': 50000};
  }

  @override
  Future<Json> earnings() async {
    await _lag();
    final d = await _d;
    _simulate(d);
    final u = _user(d);
    final bal = _balance(d, _me!);
    final rows = <Json>[];
    for (final a in _all(d, 'assignments').where((a) => a['worker_id'] == _me)) {
      final p = _paymentFor(d, a['id'] as String);
      if (p == null) continue;
      final j = _row(d, 'jobs', a['job_id'] as String);
      rows.add({'kind': 'job', 'amount_inr': p['payout'], 'state': p['state'], 'date': p['released_at'] ?? a['completed_at'] ?? j['created_at'],
        'locality': j['locality'], 'trades': [for (final it in j['items'] as List) (it as Map)['trade']].toSet().toList()});
    }
    for (final p in (d['payouts'] as List).cast<Map>().where((p) => p['worker_id'] == _me)) {
      rows.add({'kind': 'payout', 'amount_inr': p['amount'], 'state': 'processed', 'date': p['at'], 'upi': p['upi']});
    }
    rows.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    await _save();
    return {'available_inr': bal['available'], 'held_inr': bal['held'], 'total_earned_inr': bal['released'], 'paid_out_inr': bal['paid'],
      'upi': _maskUpi(u['upi'] as String?), 'kyc': _kyc(u), 'history': rows};
  }

  String? _maskUpi(String? upi) {
    if (upi == null || !upi.contains('@')) return upi;
    final parts = upi.split('@');
    return '${parts[0].substring(0, min(2, parts[0].length))}****@${parts[1]}';
  }

  @override
  Future<Json> withdraw() async {
    await _lag();
    final d = await _d;
    final u = _user(d);
    if ((u['kyc'] as int) < 1 || u['upi'] == null) _err('err.upi_required');
    final bal = _balance(d, _me!)['available'] as num;
    if (bal <= 0) _err('err.nothing_to_withdraw');
    (d['payouts'] as List).add({'worker_id': _me, 'amount': bal, 'upi': _maskUpi(u['upi'] as String), 'at': _now()});
    await _save();
    return {'amount_inr': bal, 'upi': _maskUpi(u['upi'] as String), 'ref': 'payout_demo'};
  }

  Json _breakdown(Json d, String wid) {
    final rs = (d['ratings'] as List).cast<Map>().where((r) => r['ratee'] == wid && r['direction'] == 'customer_to_worker').toList();
    final u = _user(d, wid);
    double avg(String k) => rs.isEmpty ? (u['rating'] as num).toDouble() : rs.fold<num>(0, (s, r) => s + (r[k] as num)) / rs.length;
    double r1(double v) => double.parse(v.toStringAsFixed(1));
    return {'quality': r1(avg('quality')), 'timeliness': r1(avg('timeliness')), 'behaviour': r1(avg('behaviour')),
      'value_for_money': r1(avg('value_for_money')), 'overall': r1((u['rating'] as num).toDouble()), 'count': u['rating_count']};
  }

  List<Json> _history(Json d, String wid) {
    final out = <Json>[];
    for (final r in (d['ratings'] as List).cast<Map>().where((r) => r['ratee'] == wid && r['direction'] == 'customer_to_worker')) {
      final a = _row(d, 'assignments', r['assignment_id'] as String);
      final j = _row(d, 'jobs', a['job_id'] as String);
      out.add({'job_id': j['id'], 'locality': j['locality'], 'trades': [for (final it in j['items'] as List) (it as Map)['trade']].toSet().toList(),
        'photo': _jobCard(j)['thumbnail'], 'rating': r['overall'], 'comment': r['comment'], 'date': (r['created_at'] as String).substring(0, 10)});
    }
    out.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    return out;
  }

  @override
  Future<Json> workerProfile() async {
    await _lag();
    final d = await _d;
    final u = _user(d);
    return {..._workerSummary(d, _me!), 'phone': u['phone'], 'upi': _maskUpi(u['upi'] as String?), 'is_online': u['online'],
      'breakdown': _breakdown(d, _me!), 'history': _history(d, _me!), 'kyc': _kyc(u), 'eshram_registered': u['eshram'] == true, 'strikes': 0};
  }

  @override
  Future<Json> labourCard() async {
    final d = await _d;
    final u = _user(d);
    final b = _breakdown(d, _me!);
    return {'name': u['name'], 'trades': u['trades'], 'rating': b['overall'], 'rating_count': b['count'], 'completed_jobs': u['completed'],
      'badges': u['badges'], 'breakdown': b, 'verified_level': u['kyc'], 'eshram_registered': u['eshram'] == true, 'city': 'Pune',
      'member_since': '2026-06-01', 'card_id': 'BC-${(_me!.hashCode & 0xFFFFFFF).toRadixString(16).toUpperCase().padLeft(8, '0')}'};
  }

  @override
  Future<void> kycLevel1({required String name, required String upi, String? selfieKey, List<String>? trades}) async {
    await _lag();
    if (!RegExp(r'^[a-zA-Z0-9.\-_]{2,64}@[a-zA-Z]{2,32}$').hasMatch(upi)) _err('err.validation');
    final d = await _d;
    final u = _user(d);
    u['name'] = name;
    u['upi'] = upi.toLowerCase();
    if (selfieKey != null) u['selfie'] = selfieKey;
    if (trades != null && trades.isNotEmpty) u['trades'] = trades;
    u['kyc'] = max(u['kyc'] as int, 1);
    await _save();
  }

  @override
  Future<void> kycLevel2(String docType, String docKey) async {
    final d = await _d;
    _user(d)['doc_status'] = 'pending';
    await _save();
  }

  @override
  Future<void> setOnline(bool online) async {
    final d = await _d;
    _user(d)['online'] = online;
    await _save();
  }

  /// The sample data is seeded in Pune. The first time we learn where the user really is, we
  /// move the whole sample marketplace there (keeping the shape of the city), put jobs that are
  /// already assigned ~100 m away (so check-in passes the 300 m geofence), and rename areas
  /// with the phone's geocoder. Re-anchors if the user travels > 50 km.
  @override
  Future<void> updateMyLocation(double lat, double lng) async {
    final d = await _d;
    final me = _me == null ? null : _user(d);
    if (me != null) {
      me['lat'] = lat;
      me['lng'] = lng;
    }
    final anchor = d['anchor'] as Map?;
    final far = anchor == null || _dist({'lat': anchor['lat'], 'lng': anchor['lng']}, {'lat': lat, 'lng': lng}) > 50;
    if (far) {
      const cLat = 18.5204, cLng = 73.8567; // Pune centre the seed was drawn around
      final oLat = (anchor?['lat'] as num?)?.toDouble() ?? cLat, oLng = (anchor?['lng'] as num?)?.toDouble() ?? cLng;
      void shift(Json x) {
        x['lat'] = (x['lat'] as num) - oLat + lat;
        x['lng'] = (x['lng'] as num) - oLng + lng;
      }
      for (final j in _all(d, 'jobs')) {
        if (j['sim'] == true) continue; // the user's own posts already have real coordinates
        shift(j);
      }
      for (final u in _all(d, 'users')) {
        if (u['id'] != _me) shift(u);
      }
      var k = 0;
      for (final j in _all(d, 'jobs').where((j) => j['status'] == 'assigned' || j['status'] == 'in_progress')) {
        j['lat'] = lat + 0.0007 + 0.0003 * k;
        j['lng'] = lng + 0.0005 - 0.0004 * k++;
      }
      d['anchor'] = {'lat': lat, 'lng': lng};
      await _save();
      // Rename sample areas to real nearby place names (best effort, in the background).
      () async {
        final seen = <String, String>{};
        for (final j in _all(d, 'jobs').where((j) => j['sim'] != true && !(j['id'] as String).startsWith('hj')).toList()) {
          final a = await LocationService.address((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble());
          if (a == null || a.area.isEmpty) continue;
          final old = j['locality'] as String;
          j['locality'] = seen.putIfAbsent(old, () => a.area);
          j['address'] = a.line.isEmpty ? j['address'] : a.line;
        }
        await _save();
      }();
    } else {
      await _save();
    }
  }

  // ---------------------------------------------------------------- customer
  @override
  Future<List<Json>> customerJobs() async {
    await _lag();
    final d = await _d;
    _simulate(d);
    final jobs = _all(d, 'jobs').where((j) => j['customer_id'] == _me).toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    final out = <Json>[];
    for (final j in jobs) {
      final a = _assignmentFor(d, j['id'] as String);
      final p = a == null ? null : _paymentFor(d, a['id'] as String);
      out.add({..._jobCard(j), 'bid_count': _all(d, 'bids').where((b) => b['job_id'] == j['id'] && b['status'] != 'withdrawn').length,
        'needs_rating': j['status'] == 'completed' && p?['state'] == 'held', 'worker_name': a == null ? null : _user(d, a['worker_id'] as String)['name'],
        'payment_state': p?['state']});
    }
    await _save();
    return out;
  }

  static const _basePrice = {'mason': 1200, 'plumber': 900, 'electrician': 1100, 'carpenter': 1000, 'painter': 950, 'helper': 600};

  @override
  Future<Json> priceEstimate(List<String> trades, String? locality) async {
    await _lag();
    final items = [
      for (final t in trades.toSet())
        {'trade': t, 'low_inr': (_basePrice[t]! * 1.2 / 50).round() * 50, 'median_inr': (_basePrice[t]! * 1.9 / 50).round() * 50,
          'high_inr': (_basePrice[t]! * 2.8 / 50).round() * 50, 'samples': 9 + _rnd.nextInt(6), 'scope': 'locality'}
    ];
    return {'items': items, 'total_low_inr': items.fold<int>(0, (s, i) => s + (i['low_inr'] as int)),
      'total_high_inr': items.fold<int>(0, (s, i) => s + (i['high_inr'] as int)), 'platform_fee_inr': fee};
  }

  @override
  Future<Json> createJob(Json body) async {
    await _lag();
    final items = body['work_items'] as List;
    if (items.isEmpty) _err('err.no_work_items');
    final d = await _d;
    final id = _id('j');
    _t(d, 'jobs')[id] = {
      'id': id, 'customer_id': _me, 'lat': body['location_lat'], 'lng': body['location_lng'], 'address': body['address_text'],
      'locality': body['locality'] ?? 'Pune', 'start_date': body['start_date'], 'status': 'open', 'created_at': _now(), 'sim': true,
      'items': [
        for (final w in items.cast<Map>())
          {
            'id': _id('w'), 'trade': w['trade'], 'lang': w['description_language'],
            'text': {if (w['text_description'] != null) w['description_language']: w['text_description']},
            'transcript': w['transcript'] == null ? null : {w['description_language']: w['transcript']},
            'photos': w['photo_keys'],
            'audio': w['audio_key'] == null ? null : {'url': w['audio_key'], 'duration_sec': w['audio_duration_sec'], 'size_kb': ((w['audio_size_bytes'] ?? 0) as int) ~/ 1024},
          }
      ],
    };
    await _save();
    return {'id': id, 'status': 'open'};
  }

  @override
  Future<Json> customerJob(String id) async {
    await _lag();
    final d = await _d;
    _simulate(d);
    final j = _row(d, 'jobs', id);
    final items = j['items'] as List;
    final bids = _all(d, 'bids').where((b) => b['job_id'] == id && b['status'] != 'withdrawn').toList()
      ..sort((a, b) => (a['price'] as num).compareTo(b['price'] as num));
    final a = _assignmentFor(d, id);
    await _save();
    return {
      ..._jobCard(j),
      'work_items': [for (var i = 0; i < items.length; i++) _item((items[i] as Map).cast<String, dynamic>(), i, _lang)],
      'bids': [for (final b in bids) {'id': b['id'], 'price_inr': b['price'], 'status': b['status'], 'created_at': b['created_at'], 'worker': _workerSummary(d, b['worker_id'] as String)}],
      'assignment': a == null ? null : _assignmentView(d, a), 'fee_inr': fee,
    };
  }

  @override
  Future<Json> acceptBid(String jobId, String bidId) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    final b = _row(d, 'bids', bidId);
    if (j['customer_id'] != _me) _err('err.not_your_job');
    if (b['status'] != 'pending') _err('err.job_closed');
    _doAccept(d, j, b);
    await _save();
    return {'assignment_id': _assignmentFor(d, jobId)!['id']};
  }

  @override
  Future<Json> payJob(String jobId, String method) async {
    await Future.delayed(const Duration(milliseconds: 1400)); // "processing…"
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    if (j['customer_id'] != _me) _err('err.not_your_job');
    final a = _assignmentFor(d, jobId)!;
    final p = _paymentFor(d, a['id'] as String)!;
    if (p['state'] == 'created') {
      p['state'] = 'held';
      p['method'] = method;
      p['paid_at'] = _now();
      // Presentation helper: the hired worker sets off right away so the customer can watch
      // distance + ETA. (With a real backend the worker taps "I'm on my way".)
      _beginJourney(d, a);
    }
    await _save();
    return _paymentView(p);
  }

  @override
  Future<void> completeJob(String jobId) async {
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    final a = _assignmentFor(d, jobId)!;
    if (!(j['status'] == 'assigned' || j['status'] == 'in_progress')) _err('err.job_closed');
    j['status'] = 'completed';
    a['started_at'] ??= _now();
    a['completed_at'] = _now();
    await _save();
  }

  @override
  Future<Json> rateWorker(String jobId, Json stars) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    if (j['status'] != 'completed') _err('err.job_not_completed');
    final a = _assignmentFor(d, jobId)!;
    final rs = d['ratings'] as List;
    if (rs.cast<Map>().any((r) => r['assignment_id'] == a['id'] && r['direction'] == 'customer_to_worker')) _err('err.already_rated');
    final v = [stars['quality'], stars['timeliness'], stars['behaviour'], stars['value_for_money']].cast<int>();
    if (v.any((x) => x < 1 || x > 5)) _err('err.validation');
    final overall = v.reduce((a, b) => a + b) / 4; // average of the four operational parameters
    rs.add({'assignment_id': a['id'], 'direction': 'customer_to_worker', 'ratee': a['worker_id'], 'quality': v[0], 'timeliness': v[1],
      'behaviour': v[2], 'value_for_money': v[3], 'overall': overall, 'comment': stars['comment'], 'created_at': _now()});
    final w = _user(d, a['worker_id'] as String);
    w['rating'] = double.parse((((w['rating'] as num) * (w['rating_count'] as int) + overall) / ((w['rating_count'] as int) + 1)).toStringAsFixed(2));
    w['rating_count'] = (w['rating_count'] as int) + 1;
    w['completed'] = (w['completed'] as int) + 1;
    // MANDATORY RATING GATE → release only now
    final p = _paymentFor(d, a['id'] as String)!;
    p['state'] = 'released';
    p['released_at'] = _now();
    w['earned'] = ((w['earned'] as num?) ?? 0) + (p['payout'] as num);
    await _save();
    return {'overall': overall, 'payment': _paymentView(p)};
  }

  @override
  Future<void> cancelJob(String jobId) async {
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    if (!(j['status'] == 'open' || j['status'] == 'bidding')) _err('err.job_closed');
    j['status'] = 'cancelled';
    for (final b in _all(d, 'bids').where((b) => b['job_id'] == jobId && b['status'] == 'pending')) {
      b['status'] = 'rejected';
    }
    await _save();
  }

  @override
  Future<void> dispute(String jobId, String reason) async {
    final d = await _d;
    _row(d, 'jobs', jobId)['status'] = 'disputed';
    await _save();
  }

  @override
  Future<List<Json>> payments() async {
    await _lag();
    final d = await _d;
    final out = <Json>[];
    for (final j in _all(d, 'jobs').where((j) => j['customer_id'] == _me)) {
      final a = _assignmentFor(d, j['id'] as String);
      final p = a == null ? null : _paymentFor(d, a['id'] as String);
      if (p == null) continue;
      out.add({..._paymentView(p), 'job_id': j['id'], 'locality': j['locality'], 'worker_name': _user(d, a!['worker_id'] as String)['name'],
        'trades': [for (final it in j['items'] as List) (it as Map)['trade']].toSet().toList(), 'created_at': j['created_at']});
    }
    out.sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    return out;
  }

  @override
  Future<List<Json>> browseWorkers(String? trade) async {
    await _lag();
    final d = await _d;
    final ws = _all(d, 'users').where((u) => u['role'] == 'worker' && (u['kyc'] as int) >= 1 && (trade == null || (u['trades'] as List).contains(trade))).toList()
      ..sort((a, b) => (b['rating'] as num).compareTo(a['rating'] as num));
    return [for (final w in ws) {..._workerSummary(d, w['id'] as String), 'online': w['online']}];
  }

  @override
  Future<Json> workerPublic(String workerId) async {
    await _lag();
    final d = await _d;
    return {..._workerSummary(d, workerId), 'breakdown': _breakdown(d, workerId), 'history': _history(d, workerId)};
  }

  // ---------------------------------------------------------------- shared
  @override
  Future<Json> upload(String kind, String filePath) async {
    await _lag();
    return {'key': filePath, 'url': filePath}; // demo: media stays on the phone
  }

  @override
  Future<String> transcribe(String key, String lang) async {
    await Future.delayed(const Duration(milliseconds: 900));
    return switch (lang) {
      'hi' => 'बाथरूम में नल से पानी टपक रहा है। पाइप बदलना पड़ेगा।',
      'mr' => 'बाथरूममध्ये नळ गळतोय. पाइप बदलावा लागेल.',
      _ => 'The bathroom tap is leaking. The pipe needs to be replaced.',
    };
  }

  /// Chat is stored once and read by whichever persona is signed in, exactly like the backend:
  /// a message sent as the customer shows up (unread) when the worker account opens the app.
  @override
  Future<List<Json>> chat(String jobId, String withUser) async {
    final d = await _d;
    final me = _me;
    final out = <Json>[];
    var changed = false;
    for (final m in (d['chat'] as List).cast<Map>()) {
      if (m['job_id'] != jobId) continue;
      final mine = m['from'] == me && m['to'] == withUser;
      final theirs = m['from'] == withUser && m['to'] == me;
      if (!mine && !theirs) continue;
      if (theirs && m['read'] != true) {
        m['read'] = true; // opening the thread = read
        changed = true;
      }
      out.add({'mine': mine, 'body': m['body'], 'at': m['at']});
    }
    if (changed) await _save();
    return out;
  }

  @override
  Future<void> sendChat(String jobId, String to, String body) async {
    final d = await _d;
    if (_me == null) _err('err.unauthorized');
    (d['chat'] as List).add({'job_id': jobId, 'from': _me, 'to': to, 'body': body.trim(), 'at': _now(), 'read': false});
    await _save();
  }

  @override
  Future<List<Json>> chatThreads() async {
    final d = await _d;
    final me = _me;
    if (me == null) return [];
    final threads = <String, Json>{};
    for (final m in (d['chat'] as List).cast<Map>()) {
      if (m['from'] != me && m['to'] != me) continue;
      final other = (m['from'] == me ? m['to'] : m['from']) as String;
      final key = '${m['job_id']}|$other';
      final t = threads.putIfAbsent(key, () => {'job_id': m['job_id'], 'with_user': other, 'last_body': '', 'last_at': '', 'unread': 0});
      if ((m['at'] as String).compareTo(t['last_at'] as String) >= 0) {
        t['last_body'] = m['body'];
        t['last_at'] = m['at'];
      }
      if (m['to'] == me && m['read'] != true) t['unread'] = (t['unread'] as int) + 1;
    }
    final out = <Json>[];
    for (final t in threads.values) {
      final jobs = _t(d, 'jobs');
      final users = _t(d, 'users');
      final j = (jobs[t['job_id']] as Map?)?.cast<String, dynamic>();
      final u = (users[t['with_user']] as Map?)?.cast<String, dynamic>();
      if (j == null || u == null) continue;
      out.add({
        ...t,
        'with_name': u['name'] ?? 'BuildCrew',
        'trades': ([for (final it in j['items'] as List) (it as Map)['trade'] as String]).toSet().toList(),
        'locality': j['locality'],
      });
    }
    out.sort((a, b) => (b['last_at'] as String).compareTo(a['last_at'] as String));
    return out;
  }

  @override
  Future<String> voiceQuery(String text) async {
    await _lag();
    final q = text.toLowerCase();
    final hi = _lang == 'hi';
    if (['paisa', 'पैसा', 'पैसे', 'money', 'payment', 'kab'].any(q.contains)) {
      return hi ? 'ग्राहक के रेटिंग देते ही आपका पैसा आपके UPI पर भेज दिया जाता है। आमतौर पर 1 दिन में बैंक में आ जाता है।'
          : 'Your money is released to your UPI as soon as the customer rates your work. It usually reaches your bank within 1 day.';
    }
    if (['kaam', 'काम', 'work', 'job'].any(q.contains)) {
      return hi ? 'काम टैब खोलें, काम सुनें, और \'दाम बताएँ\' दबाएँ। ग्राहक मान ले तो काम आपका।'
          : "Open the Jobs tab, listen to the work, and tap 'Quote Price'. When the customer accepts, you get the job.";
    }
    return hi ? 'माफ़ कीजिए, समझ नहीं आया। फिर से बोलें या सहायता को फ़ोन करें।' : 'Sorry, I did not understand. Please try again or call support.';
  }

  @override
  Future<String> supportTicket(String subject, String? transcript) async {
    await _lag();
    return _lang == 'hi' ? 'आपका संदेश मिल गया। हमारी टीम 2 घंटे में आपकी भाषा में जवाब देगी।'
        : 'We got your message. Our team will reply in your language within 2 hours.';
  }

  // ---------------------------------------------------------------- seed (mirrors backend/app/seed.py)
  Json _seed() {
    final now = DateTime.now();
    String ago(Duration x) => now.subtract(x).toIso8601String();
    const audio = 'asset:assets/audio/sample.ogg';
    final users = <String, dynamic>{};
    void user(String id, String phone, String role, String name, String lang,
        {List<String> trades = const [], double rating = 0, int count = 0, int kyc = 1, String loc = 'Kothrud', List<String> badges = const [], bool eshram = false}) {
      const ll = {'Kothrud': [18.5074, 73.8077], 'Baner': [18.559, 73.7868], 'Hadapsar': [18.5089, 73.926], 'Wakad': [18.5986, 73.7604],
        'Viman Nagar': [18.5679, 73.9143], 'Aundh': [18.558, 73.8075], 'Kharadi': [18.5515, 73.9348], 'Shivajinagar': [18.5308, 73.8475]};
      users[id] = {'id': id, 'phone': phone, 'role': role, 'name': name, 'lang': lang, 'kyc': kyc, 'trades': trades, 'rating': rating,
        'rating_count': count, 'completed': count, 'badges': badges, 'lat': ll[loc]![0], 'lng': ll[loc]![1], 'online': true,
        'earned': count * 2500, 'upi': kyc >= 1 ? '${name.split(' ').first.toLowerCase()}@okaxis' : null, 'eshram': eshram,
        'selfie': null};
    }

    user('a1', '9000000001', 'admin', 'Ops Admin', 'en', kyc: 2);
    user('c1', '9100000001', 'customer', 'Priya Sharma', 'hi');
    user('c2', '9100000002', 'customer', 'Anil Deshmukh', 'mr');
    user('c3', '9100000003', 'customer', 'Neha Kulkarni', 'en');
    user('w1', '9200000001', 'worker', 'Ramesh Pawar', 'mr', trades: ['mason'], rating: 4.6, count: 24, kyc: 2, badges: ['trusted_mason'], eshram: true);
    user('w2', '9200000002', 'worker', 'Sunil Yadav', 'hi', trades: ['mason', 'helper'], rating: 4.1, count: 9, loc: 'Hadapsar');
    user('w3', '9200000003', 'worker', 'Imran Shaikh', 'hi', trades: ['plumber'], rating: 4.7, count: 31, kyc: 2, loc: 'Wakad', badges: ['trusted_plumber'], eshram: true);
    user('w4', '9200000004', 'worker', 'Gopal Das', 'bn', trades: ['plumber', 'helper'], rating: 3.9, count: 6, loc: 'Kharadi');
    user('w5', '9200000005', 'worker', 'Venkat Rao', 'te', trades: ['electrician'], rating: 4.8, count: 42, kyc: 2, loc: 'Baner', badges: ['trusted_electrician', 'fast_responder'], eshram: true);
    user('w6', '9200000006', 'worker', 'Ajay Kumar', 'hi', trades: ['electrician'], rating: 4.2, count: 12, loc: 'Viman Nagar');
    user('w7', '9200000007', 'worker', 'Harpreet Singh', 'pa', trades: ['carpenter'], rating: 4.5, count: 19, loc: 'Aundh');
    user('w8', '9200000008', 'worker', 'Mohan Jadhav', 'mr', trades: ['carpenter', 'helper'], kyc: 0, loc: 'Shivajinagar');
    user('w9', '9200000009', 'worker', 'Selvam K', 'ta', trades: ['painter'], rating: 4.4, count: 15);
    user('w10', '9200000010', 'worker', 'Deepak Gupta', 'hi', trades: ['painter', 'helper'], rating: 4.0, count: 8, loc: 'Hadapsar');

    Json item(String id, String trade, Map<String, String> text, String lang,
            {bool withAudio = false, int photos = 2, String? transcript, int secs = 24, String? scene}) =>
        {
          'id': id, 'trade': trade, 'lang': lang, 'text': text, 'photos': (demoPhotos[scene ?? trade] ?? demoPhotos['helper']!).take(photos).toList(),
          'transcript': withAudio ? {'hi': transcript ?? text['hi'] ?? text.values.first, 'en': text['en'] ?? text.values.first} : null,
          'audio': withAudio ? {'url': audio, 'duration_sec': secs, 'size_kb': 18} : null,
        };
    final jobs = <String, dynamic>{};
    void job(String id, String cust, String loc, String status, Duration age, List<Json> items, {String? address}) {
      final u = users['c1'] as Json;
      const ll = {'Kothrud': [18.5074, 73.8077], 'Baner': [18.559, 73.7868], 'Hadapsar': [18.5089, 73.926], 'Wakad': [18.5986, 73.7604], 'Aundh': [18.558, 73.8075]};
      jobs[id] = {'id': id, 'customer_id': cust, 'lat': ll[loc]![0] + 0.002, 'lng': ll[loc]![1] - 0.001, 'address': address ?? 'Flat 302, Sai Residency, $loc, Pune',
        'locality': loc, 'start_date': now.add(const Duration(days: 2)).toIso8601String().substring(0, 10), 'status': status, 'created_at': ago(age),
        'sim_customer': true, 'owner_lang': u['lang']};
      jobs[id]['items'] = items;
    }

    job('j1', 'c1', 'Kothrud', 'open', const Duration(minutes: 40), [
      item('j1w1', 'plumber', {'hi': 'बाथरूम का नल टपक रहा है, पाइप बदलना है।', 'en': 'Bathroom tap is leaking, the pipe needs replacing.'}, 'hi', withAudio: true, scene: 'tap_leak'),
      item('j1w2', 'mason', {'hi': 'दीवार में सीलन, प्लास्टर ठीक करना है।', 'en': 'Damp wall, plaster needs repair.'}, 'hi', scene: 'damp_wall', photos: 3),
    ]);
    job('j2', 'c3', 'Baner', 'bidding', const Duration(hours: 5), [
      item('j2w1', 'electrician', {'en': 'Rewire the kitchen, add 4 new 16A sockets and a chimney point.', 'hi': 'किचन की वायरिंग बदलनी है, 4 नए 16A सॉकेट और चिमनी पॉइंट।'}, 'en', withAudio: true, secs: 37, photos: 3),
      item('j2w2', 'painter', {'en': 'Paint the kitchen after wiring — primer + 2 coats.', 'hi': 'वायरिंग के बाद किचन की पुताई — प्राइमर + 2 कोट।'}, 'en'),
      item('j2w3', 'helper', {'en': 'Move appliances out and clean up debris.', 'hi': 'सामान बाहर निकालना और मलबा साफ़ करना।'}, 'en', photos: 1),
    ]);
    job('j3', 'c1', 'Aundh', 'assigned', const Duration(days: 3), [
      item('j3w1', 'carpenter', {'hi': 'बेडरूम की अलमारी का दरवाज़ा टूट गया है, नया कब्ज़ा और हैंडल।', 'en': 'Bedroom wardrobe door broken — new hinge and handle.'}, 'hi', withAudio: true),
    ]);
    job('j4', 'c2', 'Hadapsar', 'in_progress', const Duration(days: 6), [
      item('j4w1', 'mason', {'mr': '40 फूट कंपाउंड भिंत, 5 फूट उंच, 9 इंची वीट.', 'hi': '40 फ़ुट कंपाउंड दीवार, 5 फ़ुट ऊँची, 9 इंच ईंट।', 'en': 'Compound wall 40 ft, 5 ft high, 9-inch brick.'}, 'mr', withAudio: true, secs: 52),
      item('j4w2', 'helper', {'hi': 'दीवार के लिए सामान ढोना, 3 दिन।', 'en': 'Material shifting for the wall, 3 days.'}, 'hi', photos: 1),
    ]);
    job('j5', 'c3', 'Kothrud', 'completed', const Duration(days: 9), [
      item('j5w1', 'painter', {'en': 'Repaint living room and hall (~900 sq ft).', 'hi': 'लिविंग रूम और हॉल की पुताई (~900 वर्ग फ़ुट)।'}, 'en'),
    ]);
    job('j6', 'c1', 'Wakad', 'bidding', const Duration(hours: 20), [
      item('j6w1', 'plumber', {'hi': 'पूरे फ्लैट की पाइपलाइन बदलनी है, लीकेज टेस्ट के साथ।', 'en': 'Replace the full flat pipeline with leak test.'}, 'hi', withAudio: true, secs: 18),
      item('j6w2', 'mason', {'en': 'Bathroom floor tiling after plumbing, 60 sq ft.', 'hi': 'प्लंबिंग के बाद बाथरूम फ़र्श टाइलिंग, 60 वर्ग फ़ुट।'}, 'en', scene: 'tiles'),
    ]);

    final bids = <String, dynamic>{};
    void bid(String id, String job, String w, int price, String status, Duration age) =>
        bids[id] = {'id': id, 'job_id': job, 'worker_id': w, 'price': price, 'status': status, 'created_at': ago(age)};
    bid('b1', 'j2', 'w5', 6800, 'pending', const Duration(hours: 4));
    bid('b2', 'j2', 'w6', 6200, 'pending', const Duration(hours: 3));
    bid('b3', 'j2', 'w9', 7400, 'pending', const Duration(hours: 2));
    bid('b4', 'j3', 'w7', 1800, 'accepted', const Duration(days: 3));
    bid('b5', 'j3', 'w8', 2100, 'rejected', const Duration(days: 3));
    bid('b6', 'j4', 'w1', 14000, 'accepted', const Duration(days: 6));
    bid('b7', 'j5', 'w9', 9000, 'accepted', const Duration(days: 8));
    bid('b8', 'j6', 'w3', 21500, 'pending', const Duration(hours: 18));
    bid('b9', 'j6', 'w4', 19800, 'pending', const Duration(hours: 10));

    final assignments = <String, dynamic>{
      'a3': {'id': 'a3', 'job_id': 'j3', 'worker_id': 'w7', 'bid_id': 'b4'},
      'a4': {'id': 'a4', 'job_id': 'j4', 'worker_id': 'w1', 'bid_id': 'b6', 'started_at': ago(const Duration(days: 2)),
        'journey_started_at': ago(const Duration(days: 2, minutes: 30))},
      'a5': {'id': 'a5', 'job_id': 'j5', 'worker_id': 'w9', 'bid_id': 'b7', 'started_at': ago(const Duration(days: 8)), 'completed_at': ago(const Duration(days: 1))},
    };
    final payments = <String, dynamic>{
      'p3': {'id': 'p3', 'assignment_id': 'a3', 'amount': 1830, 'fee': fee, 'payout': 1800, 'state': 'held', 'method': 'upi', 'paid_at': ago(const Duration(days: 3))},
      'p4': {'id': 'p4', 'assignment_id': 'a4', 'amount': 14030, 'fee': fee, 'payout': 14000, 'state': 'held', 'method': 'upi', 'paid_at': ago(const Duration(days: 6))},
      'p5': {'id': 'p5', 'assignment_id': 'a5', 'amount': 9030, 'fee': fee, 'payout': 9000, 'state': 'held', 'method': 'card', 'paid_at': ago(const Duration(days: 8))}, // awaiting rating
    };
    final ratings = <Json>[];
    // History: past rated + paid jobs for experienced workers (profile, breakdown, earnings).
    const comments = ['Very neat work', 'Came on time', 'Good behaviour, fair price', 'Bahut accha kaam', null];
    var h = 0;
    for (final w in users.values.cast<Json>().where((u) => u['role'] == 'worker' && (u['rating_count'] as int) > 0)) {
      for (var k = 0; k < 3; k++, h++) {
        final jid = 'hj$h', aid = 'ha$h', bid0 = 'hb$h', pid = 'hp$h';
        final trade = (w['trades'] as List).first as String;
        final when = now.subtract(Duration(days: 14 + k * 10));
        jobs[jid] = {'id': jid, 'customer_id': ['c1', 'c2', 'c3'][k % 3], 'lat': w['lat'], 'lng': w['lng'], 'address': 'Pune', 'locality': ['Kothrud', 'Baner', 'Aundh'][k],
          'start_date': when.toIso8601String().substring(0, 10), 'status': 'completed', 'created_at': when.subtract(const Duration(days: 3)).toIso8601String(),
          'items': [
            {...item('${jid}w', trade, {'en': '${trade[0].toUpperCase()}${trade.substring(1)} work', 'hi': 'काम'}, 'en', photos: 1),
              'photos': [demoPhotos[trade]![k % demoPhotos[trade]!.length]]}
          ]};
        final price = 1500 + _rnd.nextInt(30) * 100;
        bids[bid0] = {'id': bid0, 'job_id': jid, 'worker_id': w['id'], 'price': price, 'status': 'accepted', 'created_at': when.toIso8601String()};
        assignments[aid] = {'id': aid, 'job_id': jid, 'worker_id': w['id'], 'bid_id': bid0, 'started_at': when.toIso8601String(), 'completed_at': when.toIso8601String()};
        payments[pid] = {'id': pid, 'assignment_id': aid, 'amount': price + fee, 'fee': fee, 'payout': price, 'state': 'released', 'method': 'upi',
          'paid_at': when.subtract(const Duration(days: 2)).toIso8601String(),
          'released_at': when.add(const Duration(hours: 3)).toIso8601String()};
        final base = (w['rating'] as num).toDouble();
        int s() => (base + _rnd.nextDouble() - 0.5).round().clamp(1, 5);
        final v = [s(), s(), s(), s()];
        ratings.add({'assignment_id': aid, 'direction': 'customer_to_worker', 'ratee': w['id'], 'quality': v[0], 'timeliness': v[1], 'behaviour': v[2],
          'value_for_money': v[3], 'overall': v.reduce((a, b) => a + b) / 4, 'comment': comments[h % comments.length], 'created_at': when.add(const Duration(hours: 3)).toIso8601String()});
      }
    }
    return {
      'users': users, 'jobs': jobs, 'bids': bids, 'assignments': assignments, 'payments': payments, 'ratings': ratings,
      'payouts': [
        {'worker_id': 'w1', 'amount': 2400, 'upi': 'ra****@okaxis', 'at': ago(const Duration(days: 12))},
      ],
      'attendance': [
        // realistic site hours: 09:10 → 17:40 local time
        for (final (i, off) in [(2, false), (1, true)].indexed)
          {
            'assignment_id': 'a4',
            'in': DateTime(now.year, now.month, now.day - off.$1, 9, 10 + i * 7).toIso8601String(),
            'out': DateTime(now.year, now.month, now.day - off.$1, 17, 40 - i * 12).toIso8601String(),
            'offline': off.$2, 'geofence_ok': true,
          },
      ],
      'chat': <Json>[],
    };
  }
}
