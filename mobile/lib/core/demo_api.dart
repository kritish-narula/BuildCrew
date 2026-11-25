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

  static const _key = 'demo_db_v5';
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
  Future<void> _lag() => Future.delayed(Duration(milliseconds: 60 + _rnd.nextInt(60))); // snappy: the owner asked for fast refresh
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
      'headcount': it['headcount'] ?? 1, 'days': it['days'] ?? 1, 'daily_wage_inr': it['wage'],
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
      'police_verified': u['police'] == 'verified', 'level': _levelOf(u)['code'],
    };
  }

  Json _levelOf(Json u) => DemoLevels.levelFor((u['completed'] as int?) ?? 0, ((u['rating_count'] as int?) ?? 0) > 0 ? (u['rating'] as num).toDouble() : 0.0,
      (u['refixes'] as int?) ?? 0);

  Json _jobCard(Json j) => {
        'kind': j['kind'] ?? 'single', 'scheduled_for': j['scheduled_for'], 'time_slot': j['time_slot'],
        'team': _db == null ? null : _teamSummary(_db!, j),
        'id': j['id'], 'customer_id': j['customer_id'], 'status': j['status'], 'locality': j['locality'], 'city': (j['city'] as String?) ?? '', 'address': j['address'],
        'lat': j['lat'], 'lng': j['lng'], 'start_date': j['start_date'], 'created_at': j['created_at'],
        'trades': [for (final it in j['items'] as List) (it as Map)['trade']],
        'thumbnail': [for (final it in j['items'] as List) ...((it as Map)['photos'] as List)].cast<String?>().firstOrNull,
        'direct': _directState(j),
      };

  /// The job's ACTIVE hire (a released one — cancelled / no-show / worker withdrew — is history).
  Json? _assignmentFor(Json d, String jobId) => _all(d, 'assignments').where((a) => a['job_id'] == jobId && a['released_at'] == null).firstOrNull;
  Json? _paymentFor(Json d, String aid) => _all(d, 'payments').where((p) => p['assignment_id'] == aid).firstOrNull;

  Json _paymentView(Json p) => {
        'id': p['id'], 'amount_inr': p['amount'], 'platform_fee_inr': p['fee'], 'worker_payout_inr': p['payout'],
        'refund_inr': p['refund'] ?? 0, 'escrow_state': p['state'], 'released_at': p['released_at'], 'ref': 'BC-${(p['id'] as String).toUpperCase()}',
        'method': p['method'], 'paid_at': p['paid_at'],
      };

  Json _assignmentView(Json d, Json a, {String viewer = 'admin'}) {
    final p = _paymentFor(d, a['id'] as String);
    final ratings = <String, dynamic>{
      for (final r in (d['ratings'] as List).cast<Map>().where((r) => r['assignment_id'] == a['id'])) r['direction'] as String: r,
    };
    final bid = _row(d, 'bids', a['bid_id'] as String);
    final job = _row(d, 'jobs', a['job_id'] as String);
    final events = ((a['events'] as List?) ?? const []).cast<Map>().toList();
    final rework = a['rework_open'] == true ? events.lastWhere((e) => e['kind'] == 'rework_requested', orElse: () => <String, dynamic>{}) : null;
    final due = _autoConfirmAt(a);
    final noShow = _noShowAfter(d, a);
    final teamDays = a['item_id'] == null ? null : ((a['days'] as int?) ?? 1);
    return {
      if (viewer == 'customer') 'start_code': _customerCode(d, a),
      if (viewer == 'worker') ...{
        'start_code_state': _codeState(d, a), 'start_code_locked_until': _locked(a) ? a['code_locked_until'] : null,
      },
      if (a['kind'] == 'refix') 'refix': {'parent_job_id': _row(d, 'assignments', a['parent'] as String)['job_id'], 'reason': a['refix_reason']},
      'kind': (a['kind'] as String?) ?? 'job', 'warranty': _warrantyView(d, a),
      if (teamDays != null) ...{
        'team_member': true, 'trade': (_row(d, 'jobs', a['job_id'] as String)['items'] as List).cast<Map>().firstWhere((x) => x['id'] == a['item_id'])['trade'],
        'daily_wage_inr': bid['price'], 'days_planned': teamDays, 'days_worked': _daysWorked(d, a),
      },
      'proof_photos': a['proof'] ?? <String>[], 'worker_done_note': a['done_note'],
      'before_photos': [for (final it in job['items'] as List) ...((it as Map)['photos'] as List)],
      'rework_count': a['rework_count'] ?? 0, 'rework_left': max(0, _maxRework - ((a['rework_count'] as int?) ?? 0)), 'rework_open': a['rework_open'] == true,
      'rework': rework == null || rework.isEmpty ? null : {'reasons': rework['reasons'], 'note': rework['note'], 'at': rework['at'], 'photos': rework['photos']},
      'auto_confirm_at': due == null ? null : due.toIso8601String(), 'auto_confirm_hours': _autoConfirm.inHours, 'auto_confirmed': a['auto_confirmed'] == true,
      'no_show_after': noShow?.toIso8601String(), 'can_report_no_show': noShow != null && !DateTime.now().isBefore(noShow),
      'worker_suspended': _user(d, a['worker_id'] as String)['suspended'] == true,
      'timeline': [for (final e in events) {'kind': e['kind'], 'by': e['by'], 'at': e['at'], 'reasons': e['reasons'] ?? <String>[], 'note': e['note'], 'photos': e['photos'] ?? <String>[]}],
      'tracking': _tracking(d, a), 'worker_done_at': a['worker_done_at'],
      'id': a['id'], 'worker': _workerSummary(d, a['worker_id'] as String), 'price_inr': teamDays == null ? bid['price'] : (bid['price'] as num) * teamDays,
      'started_at': a['started_at'], 'completed_at': a['completed_at'], 'payment': p == null ? null : _paymentView(p),
      'ratings': ratings,
      'attendance': [
        for (final x in (d['attendance'] as List).cast<Map>().where((x) => x['assignment_id'] == a['id']))
          {'in': x['in'], 'out': x['out'], 'offline': x['offline'], 'geofence_ok': x['geofence_ok'], 'selfie': x['selfie'],
            'code_status': (x['code_status'] as String?) ?? 'not_required'}
      ],
    };
  }

  // ---------------------------------------------------------------- team hiring helpers (mirror backend/app/domain/team.py)
  List<Json> _asgOf(Json d, String jobId) => _all(d, 'assignments').where((a) => a['job_id'] == jobId).toList();
  int _filled(Json d, String itemId) => _all(d, 'assignments').where((a) => a['item_id'] == itemId).length;
  int _openSlots(Json d, Json j) =>
      (j['items'] as List).cast<Map>().fold<int>(0, (s, it) => s + max(0, ((it['headcount'] as int?) ?? 1) - _filled(d, it['id'] as String)));

  Iterable<DateTime> _checkins(Json d, Json a) =>
      (d['attendance'] as List).cast<Map>().where((x) => x['assignment_id'] == a['id'] && _codeOk(x)).map((x) => DateTime.parse(x['in'] as String).toLocal());

  /// Distinct calendar days with a check-in, capped at the planned days.
  int _daysWorked(Json d, Json a) {
    final days = {for (final t in _checkins(d, a)) '${t.year}-${t.month}-${t.day}'};
    return min(days.length, (a['days'] as int?) ?? 1);
  }

  bool _presentToday(Json d, Json a) {
    final n = DateTime.now();
    return _checkins(d, a).any((t) => t.year == n.year && t.month == n.month && t.day == n.day);
  }

  Json? _teamSummary(Json d, Json j) {
    if (j['kind'] != 'team') return null;
    final asg = _asgOf(d, j['id'] as String);
    final lines = <Json>[
      for (final it in (j['items'] as List).cast<Map>())
        {'item_id': it['id'], 'trade': it['trade'], 'headcount': it['headcount'] ?? 1,
          'filled': asg.where((a) => a['item_id'] == it['id']).length, 'days': it['days'] ?? 1, 'daily_wage_inr': it['wage']}
    ];
    return {'headcount': lines.fold<int>(0, (s, i) => s + (i['headcount'] as int)), 'filled': lines.fold<int>(0, (s, i) => s + (i['filled'] as int)),
      'present_today': asg.where((a) => _presentToday(d, a)).length, 'items': lines};
  }

  Json _roster(Json d, Json j) {
    final rows = <Json>[];
    num due = 0;
    var dueN = 0;
    for (final a in _asgOf(d, j['id'] as String)) {
      final p = _paymentFor(d, a['id'] as String);
      final wage = _row(d, 'bids', a['bid_id'] as String)['price'] as num;
      final it = (j['items'] as List).cast<Map>().firstWhere((x) => x['id'] == a['item_id']);
      final days = (a['days'] as int?) ?? 1, worked = _daysWorked(d, a);
      if (p != null && p['state'] == 'created') {
        due += p['amount'] as num;
        dueN++;
      }
      rows.add({
        'assignment_id': a['id'], 'worker': _workerSummary(d, a['worker_id'] as String), 'trade': it['trade'], 'daily_wage_inr': wage,
        'days_planned': days, 'days_worked': worked, 'present_today': _presentToday(d, a), 'amount_due_inr': wage * worked,
        'total_inr': wage * days, 'payment': p == null ? null : _paymentView(p),
        'rated': (d['ratings'] as List).cast<Map>().any((r) => r['assignment_id'] == a['id'] && r['direction'] == 'customer_to_worker'),
        'settled': p != null && const ['released', 'refunded', 'split'].contains(p['state']),
        'start_code': _teamDayCode(d, a), 'warranty': _warrantyView(d, a),
      });
    }
    return {'summary': _teamSummary(d, j), 'workers': rows, 'payment_due_inr': due, 'payment_due_count': dueN};
  }

  /// Accept one applicant of a team job: his own assignment + escrow (wage x days + fee). Several per trade, up to headcount.
  Json _acceptTeam(Json d, Json job, Json bid) {
    final it = (job['items'] as List).cast<Map>().where((x) => x['id'] == bid['item_id']).firstOrNull ?? _err('err.not_found');
    if (!const ['open', 'bidding', 'assigned', 'in_progress'].contains(job['status'])) _err('err.job_closed');
    if (_filled(d, it['id'] as String) >= ((it['headcount'] as int?) ?? 1)) _err('err.team_full');
    if (job['status'] == 'open' || job['status'] == 'bidding') job['status'] = 'assigned';
    bid['status'] = 'accepted';
    final aid = _id('a'), days = (it['days'] as int?) ?? 1;
    _t(d, 'assignments')[aid] = {'id': aid, 'job_id': job['id'], 'worker_id': bid['worker_id'], 'bid_id': bid['id'], 'item_id': it['id'], 'days': days};
    final pid = _id('p'), total = (bid['price'] as num) * days;
    _t(d, 'payments')[pid] = {'id': pid, 'assignment_id': aid, 'amount': total + fee, 'fee': fee, 'payout': total, 'state': 'created'};
    if (_openSlots(d, job) == 0) {
      for (final o in _all(d, 'bids').where((x) => x['job_id'] == job['id'] && x['status'] == 'pending')) {
        o['status'] = 'rejected';
      }
    }
    return _row(d, 'assignments', aid);
  }

  /// Not in the past: a slot stays bookable until it ends, an exact time needs >= now - 2 min.
  void _validateSchedule(Json body) {
    final now = DateTime.now();
    final sd = DateTime.parse(body['start_date'] as String);
    if (DateTime(sd.year, sd.month, sd.day).isBefore(DateTime(now.year, now.month, now.day))) _err('err.date_in_past');
    final raw = body['scheduled_for'] as String?;
    if (raw == null) return;
    final at = DateTime.parse(raw).toLocal();
    const ends = {'morning': 11, 'afternoon': 15, 'evening': 19};
    final slot = body['time_slot'];
    if (ends.containsKey(slot)) {
      if (!DateTime(at.year, at.month, at.day, ends[slot]!).isAfter(now)) _err('err.schedule_past');
    } else if (at.isBefore(now.subtract(const Duration(minutes: 2)))) {
      _err('err.schedule_past');
    }
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
    // (also starts the no-show clock: ETA at departure + 60 min, see _noShowAfter)
    final j = _row(d, 'jobs', a['job_id'] as String);
    Map<String, dynamic> from;
    if (lat != null && lng != null && _dist({'lat': lat, 'lng': lng}, j) > 0.5) {
      from = {'lat': lat, 'lng': lng};
    } else {
      from = {'lat': (j['lat'] as num) + 0.021, 'lng': (j['lng'] as num) - 0.014}; // ≈ 2.8 km away
    }
    a['journey_from'] = from;
    a['journey_started_at'] = _now();
    final km = _dist({'lat': from['lat'], 'lng': from['lng']}, j);
    a['expected_arrival_at'] = DateTime.now().add(Duration(minutes: km > 0.15 ? max(1, (km / 20 * 60).round()) : 30)).toIso8601String();
  }

  double _dist(Json u, Json j) {
    double r(double v) => v * pi / 180;
    final la1 = r((u['lat'] as num).toDouble()), la2 = r((j['lat'] as num).toDouble());
    final dl = r((j['lng'] as num).toDouble() - (u['lng'] as num).toDouble());
    final h = pow(sin((la2 - la1) / 2), 2) + cos(la1) * cos(la2) * pow(sin(dl / 2), 2);
    return 2 * 6371 * asin(sqrt(h));
  }

  // ---------------------------------------------------------------- pricing helpers (see DemoPricing)
  String? _pricingText(Json it) {
    final t = _text(it, 'en');
    if (t != null && t.isNotEmpty) return t;
    final tr = (it['transcript'] as Map?)?.cast<String, dynamic>();
    return tr == null || tr.isEmpty ? null : (tr['en'] ?? tr.values.first) as String?;
  }

  List<(String, String?)> _pricingItems(Json j) => [
        for (final it in (j['items'] as List).cast<Map>()) (it['trade'] as String, _pricingText(it.cast<String, dynamic>()))
      ];

  String _cityOf(Json d, Json j) => (j['city'] as String?) ?? (d['city'] as String?) ?? '';

  // ---------------------------------------------------------------- marketplace simulation
  /// Workers quote on a customer's new job ~15 s after posting; a customer accepts a worker's
  /// lowest pending quote ~30 s after it was placed. Lazy: evaluated whenever data is read.
  void _simulate(Json d) {
    _sweepAuto(d); // 48 h auto-confirm is evaluated on every read, like the backend does on list/detail
    _settlePayouts(d); // same-day pay: processing -> paid after ~5 s
    final now = DateTime.now();
    for (final u in _all(d, 'users')) {
      // police verification: a request made from this phone is approved ~20 s later (the partner check, simulated)
      final req = _at(u['police_requested_at']);
      if (u['police'] == 'pending' && u['police_auto'] == true && req != null && now.difference(req) >= policeAutoApprove) {
        u['police'] = 'verified';
        u['police_decided_at'] = _now();
      }
    }
    for (final j in _all(d, 'jobs').toList()) {
      if (!(j['status'] == 'open' || j['status'] == 'bidding') || j['sim'] != true || j['kind'] == 'team') continue;
      if (now.difference(DateTime.parse(j['created_at'] as String)).inSeconds < 15) continue;
      final trades = {for (final it in j['items'] as List) (it as Map)['trade']};
      final have = _all(d, 'bids').where((b) => b['job_id'] == j['id']).length;
      if (have > 0) continue;
      final directTo = _exclusiveTo(j);
      final pool = directTo != null
          ? [_row(d, 'users', directTo)] // "send to Ramesh first": only he is asked during the 2 hours
          : _all(d, 'users').where((u) => u['role'] == 'worker' && (u['trades'] as List).any(trades.contains)).take(3).toList();
      final items = _pricingItems(j), city = _cityOf(d, j);
      for (final w in pool) {
        // Quotes land around the fair-price model, +/-15%.
        final median = DemoPricing.fairRange(items, city, w['trades'] as List)['median'] as num;
        final price = max(100, (median * (0.85 + _rnd.nextDouble() * 0.3) / 50).round() * 50);
        final id = _id('b');
        _t(d, 'bids')[id] = {'id': id, 'job_id': j['id'], 'worker_id': w['id'], 'price': price, 'status': 'pending', 'created_at': _now()};
      }
      if (pool.isNotEmpty) j['status'] = 'bidding';
    }
    // team jobs posted from this phone: workers apply ~15 s later (headcount join at the offered wage, one counter-offer)
    for (final j in _all(d, 'jobs').where((j) => j['kind'] == 'team' && j['sim'] == true && j['status'] == 'open').toList()) {
      if (now.difference(DateTime.parse(j['created_at'] as String)).inSeconds < 15) continue;
      if (_all(d, 'bids').any((b) => b['job_id'] == j['id'])) continue;
      final used = <String>{};
      for (final it in (j['items'] as List).cast<Map>()) {
        final pool = _all(d, 'users').where((u) => u['role'] == 'worker' && (u['kyc'] as int) >= 1 && (u['trades'] as List).contains(it['trade']) && !used.contains(u['id'])).toList()
          ..sort((a, b) => (b['rating'] as num).compareTo(a['rating'] as num));
        final head = (it['headcount'] as int?) ?? 1;
        for (final (k, w) in pool.take(head + 1).indexed) {
          used.add(w['id'] as String);
          final id = _id('b');
          _t(d, 'bids')[id] = {'id': id, 'job_id': j['id'], 'worker_id': w['id'], 'item_id': it['id'],
            'price': (it['wage'] as num) + (k >= head ? 100 : 0), 'status': 'pending', 'created_at': _now()};
        }
      }
      j['status'] = 'bidding';
    }
    // demo only: workers hired for a team site posted from this phone check in ~20 s after the team is paid
    for (final a in _all(d, 'assignments').where((a) => a['item_id'] != null && a['worker_id'] != _me).toList()) {
      final p = _paymentFor(d, a['id'] as String);
      final job = _row(d, 'jobs', a['job_id'] as String);
      if (p == null || p['state'] != 'held' || p['paid_at'] == null || job['sim'] != true) continue;
      if (now.difference(DateTime.parse(p['paid_at'] as String)).inSeconds < 20 || _presentToday(d, a)) continue;
      (d['attendance'] as List).add({'assignment_id': a['id'], 'in': _now(), 'out': null, 'offline': false, 'geofence_ok': true,
        'client_ref': 'sim-${a['id']}-${now.day}', 'selfie': null, 'code_status': 'verified'});
      if (job['status'] == 'assigned') job['status'] = 'in_progress';
      a['started_at'] ??= _now();
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
    if (paid) _t(d, 'assignments')[aid]!['nonce'] = _id('n');
  }

  void _requirePaid(Json d, Json a) {
    if (a['released_at'] != null) _err('err.hire_cancelled');
    if (_paymentFor(d, a['id'] as String)?['state'] == 'created') _err('err.payment_pending');
  }

  // ---------------------------------------------------------------- completion flow (mirrors backend/app/domain/flows.py)
  static const _autoConfirm = Duration(hours: 48); // customer silent this long after "work finished" → auto-confirmed + paid
  static const _maxRework = 2; // "send back" rounds; the 3rd disagreement opens a dispute
  static const _reworkReasons = ['incomplete', 'poor_quality', 'damage', 'not_came', 'other'];
  static const _noShowGrace = Duration(minutes: 60);

  DateTime? _at(Object? v) => v is String ? DateTime.tryParse(v) : null;

  Json _own(Json d, String jobId) {
    final j = _row(d, 'jobs', jobId);
    if (j['customer_id'] != _me) _err('err.not_found');
    return j;
  }

  void _event(Json a, String kind, String by, {List<String> reasons = const [], String? note, List<String> photos = const []}) {
    ((a['events'] ??= <dynamic>[]) as List).add({'kind': kind, 'by': by, 'at': _now(), 'reasons': reasons, 'note': note, 'photos': photos});
  }

  bool _rated(Json d, Json a) =>
      (d['ratings'] as List).cast<Map>().any((r) => r['assignment_id'] == a['id'] && r['direction'] == 'customer_to_worker');

  DateTime? _autoConfirmAt(Json a) {
    final done = _at(a['worker_done_at']);
    if (done == null || a['rework_open'] == true || a['released_at'] != null || a['auto_confirmed'] == true) return null;
    return done.add(_autoConfirm);
  }

  /// Neutral rating: releases the money (the mandatory-rating gate stays intact) but scores nothing.
  void _autoRate(Json d, Json a, Json p) {
    if (_rated(d, a)) return;
    (d['ratings'] as List).add({'assignment_id': a['id'], 'direction': 'customer_to_worker', 'ratee': a['worker_id'], 'overall': 0.0,
      'is_auto': true, 'comment': null, 'created_at': _now()});
    final w = _user(d, a['worker_id'] as String);
    w['completed'] = (w['completed'] as int) + 1; // the job counts; the average and rating_count do not move
    w['earned'] = ((w['earned'] as num?) ?? 0) + (p['payout'] as num);
    p['state'] = 'released';
    p['released_at'] = _now();
    _autoPayout(d, a, p['payout'] as num);
  }

  /// The 48 h rule. Only for money that is HELD; never during a dispute; never for a released hire.
  void _sweepAuto(Json d) {
    final now = DateTime.now();
    for (final a in _all(d, 'assignments').toList()) {
      if (a['released_at'] != null || a['no_auto'] == true) continue;
      final p = _paymentFor(d, a['id'] as String);
      if (a['kind'] == 'refix') {
        // free visit: 48 h of silence confirms it (nothing to pay or rate)
        final rj = _row(d, 'jobs', a['job_id'] as String);
        final rdue = _autoConfirmAt(a);
        if (rj['status'] == 'in_progress' && rdue != null && !now.isBefore(rdue)) {
          rj['status'] = 'completed';
          a['completed_at'] = _now();
          a['auto_confirmed'] = true;
          _event(a, 'auto_confirmed', 'system');
        }
        continue;
      }
      if (p == null || p['state'] != 'held') continue;
      final j = _row(d, 'jobs', a['job_id'] as String);
      final due = _autoConfirmAt(a);
      final doneAt = _at(a['completed_at']);
      if (j['status'] == 'in_progress' && due != null && !now.isBefore(due)) {
        j['status'] = 'completed';
        a['completed_at'] = _now();
        a['auto_confirmed'] = true;
        _event(a, 'auto_confirmed', 'system');
        _autoRate(d, a, p);
      } else if (j['status'] == 'completed' && doneAt != null && !now.isBefore(doneAt.add(_autoConfirm)) && !_rated(d, a)) {
        a['auto_confirmed'] = true;
        _event(a, 'auto_rated', 'system');
        _autoRate(d, a, p);
      }
    }
  }

  void _strike(Json d, String workerId) {
    final u = _user(d, workerId);
    u['strikes'] = ((u['strikes'] as int?) ?? 0) + 1;
    if ((u['strikes'] as int) >= 3) u['suspended'] = true;
  }

  /// Unpaid order → voided; held → refunded IN FULL (quote + fee). Settled money is never touched.
  num _voidOrRefund(Json d, Json a) {
    final p = _paymentFor(d, a['id'] as String);
    if (p == null) return 0;
    if (p['state'] == 'created') {
      _t(d, 'payments').remove(p['id']);
      return 0;
    }
    if (p['state'] != 'held') _err('err.payment_not_held');
    final amount = p['amount'] as num;
    p['state'] = 'refunded';
    p['refund'] = amount;
    p['payout'] = 0;
    p['fee'] = 0;
    p['released_at'] = _now();
    return amount;
  }

  /// End a hire BEFORE work started. reopen → back on the market (earlier quotes return); else the job is cancelled.
  Json _releaseHire(Json d, Json a, String reason, {required bool reopen}) {
    final j = _row(d, 'jobs', a['job_id'] as String);
    if (a['released_at'] != null) return {'status': j['status'], 'refunded_inr': 0};
    if (j['status'] == 'in_progress' || j['status'] == 'disputed' || j['status'] == 'completed' || a['started_at'] != null || a['worker_done_at'] != null) {
      _err('err.job_started');
    }
    if (j['status'] != 'assigned') _err('err.job_closed');
    final paid = _paymentFor(d, a['id'] as String)?['state'] == 'held';
    final refunded = _voidOrRefund(d, a);
    a['released_at'] = _now();
    a['release_reason'] = reason;
    _row(d, 'bids', a['bid_id'] as String)['status'] = 'withdrawn';
    _event(a, 'released', reason == 'worker_withdrew' ? 'worker' : 'customer', reasons: [reason]);
    if (reopen) {
      var revived = 0;
      for (final o in _all(d, 'bids').where((b) => b['job_id'] == j['id'] && b['status'] == 'rejected')) {
        o['status'] = 'pending';
        revived++;
      }
      j['status'] = revived > 0 ? 'bidding' : 'open';
    } else {
      j['status'] = 'cancelled';
    }
    if (paid && (reason == 'worker_withdrew' || reason == 'no_show')) _strike(d, a['worker_id'] as String);
    return {'status': j['status'], 'refunded_inr': refunded};
  }

  /// ETA given at departure + 60 min (worker never set off: start date 09:00 + 3 h). null = not reportable.
  DateTime? _noShowAfter(Json d, Json a) {
    if (a['started_at'] != null || a['worker_done_at'] != null || a['released_at'] != null) return null;
    final exp = _at(a['expected_arrival_at']);
    if (exp != null) return exp.add(_noShowGrace);
    final js = _at(a['journey_started_at']);
    if (js != null) return js.add(const Duration(minutes: 90));
    final p = _paymentFor(d, a['id'] as String);
    final paid = _at(p?['paid_at']);
    if (p == null || p['state'] != 'held' || paid == null) return null;
    final start = DateTime.tryParse('${_row(d, 'jobs', a['job_id'] as String)['start_date']}T09:00:00') ?? paid;
    return (paid.isAfter(start) ? paid : start).add(const Duration(minutes: 180));
  }

  /// Money stays frozen; the demo "support team" decides when [demoSkipTime] passes 24 h (50/50 split).
  Json _openDispute(Json d, Json a, String reason, String byRole, {bool auto = false}) {
    final j = _row(d, 'jobs', a['job_id'] as String);
    final list = (d['disputes'] ??= <dynamic>[]) as List;
    if (j['status'] == 'disputed') {
      final open = list.cast<Map>().where((x) => x['assignment_id'] == a['id'] && x['status'] != 'resolved').lastOrNull;
      if (open != null) return open.cast<String, dynamic>();
    }
    if (!(j['status'] == 'assigned' || j['status'] == 'in_progress' || j['status'] == 'completed')) _err('err.job_closed');
    if (reason.trim().length < 5) _err('err.validation');
    if (_paymentFor(d, a['id'] as String)?['state'] != 'held') _err('err.payment_not_held');
    if (byRole == 'worker' && a['started_at'] == null && a['worker_done_at'] == null) _err('err.too_early_to_dispute');
    j['status'] = 'disputed';
    final row = <String, dynamic>{'id': _id('d'), 'assignment_id': a['id'], 'reason': reason.trim(), 'by': byRole, 'status': 'open', 'created_at': _now()};
    list.add(row);
    final t = reason.trim();
    _event(a, 'disputed', auto ? 'system' : byRole, note: t.length > 500 ? t.substring(0, 500) : t);
    return row;
  }

  void _demoResolveDispute(Json d, Json a) {
    final p = _paymentFor(d, a['id'] as String);
    final j = _row(d, 'jobs', a['job_id'] as String);
    if (p == null || p['state'] != 'held') return;
    final payout = p['payout'] as num;
    final half = (payout / 2).round();
    p['refund'] = (p['amount'] as num) - half - (p['fee'] as num);
    p['payout'] = half;
    p['state'] = 'split';
    p['released_at'] = _now();
    final w = _user(d, a['worker_id'] as String);
    w['earned'] = ((w['earned'] as num?) ?? 0) + half;
    _autoPayout(d, a, half);
    j['status'] = 'completed';
    a['completed_at'] ??= _now();
    a['rework_open'] = false;
    for (final x in ((d['disputes'] as List?) ?? const []).cast<Map>().where((x) => x['assignment_id'] == a['id'])) {
      x['status'] = 'resolved';
    }
    _event(a, 'dispute_resolved', 'admin', note: 'worker_share=50%');
  }

  @override
  Future<void> demoSkipTime(String jobId, Duration by) async {
    final d = await _d;
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    for (final k in ['worker_done_at', 'completed_at', 'expected_arrival_at']) {
      final t = _at(a[k]);
      if (t != null) a[k] = t.subtract(by).toIso8601String();
    }
    final p = _paymentFor(d, a['id'] as String);
    for (final k in ['paid_at', 'released_at']) {
      final t = _at(p?[k]);
      if (p != null && t != null) p[k] = t.subtract(by).toIso8601String();
    }
    final dj = _row(d, 'jobs', jobId);
    final du = _at(dj['direct_until']);
    if (du != null) dj['direct_until'] = du.subtract(by).toIso8601String();
    if (_row(d, 'jobs', jobId)['status'] == 'disputed' && by >= const Duration(hours: 24)) _demoResolveDispute(d, a);
    _sweepAuto(d);
    await _save();
  }

  // ---------------------------------------------------------------- trust & worker features
  // Mirrors backend/app/domain/trust.py + levels.py (same limits, same error codes). Keep both in sync.
  static const startCodeMaxAttempts = 5;
  static const startCodeLockMinutes = 10;
  static const policeAutoApprove = Duration(seconds: 20); // the partner check, simulated
  static const payoutSettle = Duration(seconds: 5);
  static const directHours = 2;
  static const maxRefix = 2;
  static const tripBase = 'https://buildcrew.app/t';
  static const warrantyByTrade = {'plumber': 30, 'electrician': 30, 'carpenter': 15, 'mason': 15, 'painter': 7, 'helper': 0};

  // -- 1. start-work code: derived from a per-hire nonce (+ the day for team members); the worker view never carries it
  String _dayKey(Json a, [DateTime? at]) {
    if (a['item_id'] == null) return 'once';
    final t = (at ?? DateTime.now()).toLocal();
    return '${t.year}-${t.month}-${t.day}';
  }

  String? _codeFor(Json a, [DateTime? at]) {
    final n = a['nonce'] as String?;
    if (n == null) return null;
    var h = 7;
    for (final c in '${a['id']}:$n:${_dayKey(a, at)}'.codeUnits) {
      h = (h * 131 + c) % 9999991;
    }
    return (h % 10000).toString().padLeft(4, '0');
  }

  bool _codeOk(Map x) => x['code_status'] == null || x['code_status'] == 'verified' || x['code_status'] == 'not_required';

  bool _codeRequired(Json d, Json a, [DateTime? at]) {
    if (a['nonce'] == null || a['released_at'] != null) return false;
    if (a['item_id'] != null) {
      final t = (at ?? DateTime.now()).toLocal();
      return !(d['attendance'] as List).cast<Map>().any((x) =>
          x['assignment_id'] == a['id'] && _codeOk(x) && _sameDay(DateTime.parse(x['in'] as String).toLocal(), t));
    }
    return a['started_at'] == null;
  }

  bool _locked(Json a) {
    final u = _at(a['code_locked_until']);
    return u != null && DateTime.now().isBefore(u);
  }

  int _lockMinutes(Json a) => max(1, (_at(a['code_locked_until'])!.difference(DateTime.now()).inSeconds / 60).ceil());

  /// Counts attempts: 5 wrong tries lock the hire for 10 minutes. strict=false (offline sync) just returns false.
  bool _verifyCode(Json a, String? code, DateTime? at, {bool strict = true}) {
    if (_locked(a)) {
      if (strict) throw ApiException('err.start_code_locked', '${_lockMinutes(a)}');
      return false;
    }
    if (a['code_locked_until'] != null) {
      a['code_locked_until'] = null;
      a['code_attempts'] = 0;
    }
    final day = _dayKey(a, at);
    if (a['code_attempts_day'] != day) {
      a['code_attempts'] = 0;
      a['code_attempts_day'] = day;
    }
    if (code != null && code.trim() == _codeFor(a, at)) {
      a['code_attempts'] = 0;
      return true;
    }
    final n = ((a['code_attempts'] as int?) ?? 0) + 1;
    a['code_attempts'] = n;
    if (n >= startCodeMaxAttempts) {
      a['code_locked_until'] = DateTime.now().add(const Duration(minutes: startCodeLockMinutes)).toIso8601String();
      a['code_attempts'] = 0;
      if (strict) throw ApiException('err.start_code_locked', '$startCodeLockMinutes');
      return false;
    }
    if (strict) throw ApiException('err.start_code_invalid', '${startCodeMaxAttempts - n}');
    return false;
  }

  /// Worker-facing state, no secrets: null | needed | locked | verified | pending | failed.
  String? _codeState(Json d, Json a) {
    if (a['nonce'] == null || a['released_at'] != null) return null;
    if (_codeRequired(d, a)) {
      if (_locked(a)) return 'locked';
      final last = (d['attendance'] as List).cast<Map>().where((x) => x['assignment_id'] == a['id']).lastOrNull;
      if (last != null && (last['code_status'] == 'pending' || last['code_status'] == 'failed')) return last['code_status'] as String;
      return 'needed';
    }
    return 'verified';
  }

  /// What the CUSTOMER sees: the code itself while it is still needed (after paying; a re-fix needs no payment).
  Json? _customerCode(Json d, Json a) {
    if (a['nonce'] == null || a['released_at'] != null) return null;
    final p = _paymentFor(d, a['id'] as String);
    final paid = a['kind'] == 'refix' || const ['held', 'released', 'split'].contains(p?['state']);
    if (!paid) return null;
    final need = _codeRequired(d, a);
    return {'code': need ? _codeFor(a) : null, 'needed': need, 'state': _codeState(d, a),
      'locked_until': _locked(a) ? a['code_locked_until'] : null, 'attempts_left': max(0, startCodeMaxAttempts - ((a['code_attempts'] as int?) ?? 0))};
  }

  /// Contractor roster: today's code for this team member.
  Json? _teamDayCode(Json d, Json a) {
    final v = _customerCode(d, a);
    if (v == null) return null;
    return {'code': _codeFor(a), 'verified_today': v['needed'] != true, 'state': v['state'], 'locked_until': v['locked_until']};
  }

  // -- 3. police verification
  @override
  Future<Json> requestPoliceVerification() async {
    await _lag();
    final d = await _d;
    final u = _user(d);
    if ((u['kyc'] as int) < 1) _err('err.kyc_required');
    final st = (u['police'] as String?) ?? 'none';
    if (st == 'pending' || st == 'verified') return {'status': st};
    u['police'] = 'pending';
    u['police_requested_at'] = _now();
    u['police_auto'] = true; // demo: the partner "approves" ~20 s later
    u['police_note'] = null;
    await _save();
    return {'status': 'pending'};
  }

  // -- 4. warranty + free re-fix
  int _warrantyDays(Iterable<String> trades) => trades.fold<int>(0, (m, t) => max(m, warrantyByTrade[t] ?? 0));

  List<String> _asgTrades(Json d, Json a) {
    final items = (_row(d, 'jobs', a['job_id'] as String)['items'] as List).cast<Map>();
    if (a['item_id'] != null) return [for (final it in items) if (it['id'] == a['item_id']) it['trade'] as String];
    return _quoteTrades(d, _row(d, 'jobs', a['job_id'] as String), a['worker_id'] as String);
  }

  /// Trades of the job that this worker would do (all of them when none match).
  List<String> _quoteTrades(Json d, Json j, String workerId) {
    final mine = _user(d, workerId)['trades'] as List;
    final all = [for (final it in j['items'] as List) (it as Map)['trade'] as String];
    final f = all.where(mine.contains).toList();
    return f.isEmpty ? all : f;
  }

  List<Json> _refixesOf(Json d, Json a) => _all(d, 'assignments').where((k) => k['parent'] == a['id'] && k['released_at'] == null).toList();

  Json? _settledPayment(Json d, Json a) {
    final p = _paymentFor(d, a['id'] as String);
    return p != null && (p['state'] == 'released' || p['state'] == 'split') && (p['payout'] as num) > 0 ? p : null;
  }

  Json? _warrantyView(Json d, Json a) {
    if (a['kind'] == 'refix') return null;
    final days = _warrantyDays(_asgTrades(d, a));
    final p = _settledPayment(d, a);
    final kids = _refixesOf(d, a);
    final openKid = kids.where((k) => !const ['completed', 'cancelled'].contains(_row(d, 'jobs', k['job_id'] as String)['status'])).firstOrNull;
    final out = <String, dynamic>{'days': days, 'until': null, 'active': false, 'refixes_used': kids.length, 'refixes_max': maxRefix,
      'open_job_id': openKid?['job_id'], 'can_request': false, 'reason': null};
    final rel = _at(p?['released_at']);
    if (p == null || rel == null) {
      out['reason'] = 'not_released';
      return out;
    }
    final until = rel.add(Duration(days: days));
    out['until'] = until.toIso8601String();
    out['active'] = days > 0 && !DateTime.now().isAfter(until);
    if (out['active'] != true) {
      out['reason'] = 'expired';
    } else if (openKid != null) {
      out['reason'] = 'open';
    } else if (kids.length >= maxRefix) {
      out['reason'] = 'limit';
    } else {
      out['can_request'] = true;
    }
    return out;
  }

  Json _warrantyRecord(Json u) {
    final jobs = (u['completed'] as int?) ?? 0, fixes = (u['refixes'] as int?) ?? 0;
    return {'refixes': fixes, 'jobs': jobs, 'rate': DemoLevels.refixRate(jobs, fixes)};
  }

  @override
  Future<Json> requestRefix(String jobId, {required String reason, List<String> photos = const [], String? assignmentId}) async {
    await _lag();
    final d = await _d;
    final job = _own(d, jobId);
    final Json a;
    if (job['kind'] == 'team') {
      a = _row(d, 'assignments', assignmentId ?? _err('err.not_found'));
      if (a['job_id'] != jobId) _err('err.not_found');
    } else {
      a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    }
    if (a['kind'] == 'refix') _err('err.validation');
    final why = reason.trim();
    if (why.length < 5 || why.length > 1000) _err('err.validation');
    final ph = [for (final x in photos) if (x.trim().isNotEmpty) x.trim()];
    if (ph.length > 5) _err('err.too_many_photos');
    if (ph.isEmpty) _err('err.proof_required');
    if (_settledPayment(d, a) == null) _err('err.job_not_completed');
    final wv = _warrantyView(d, a)!;
    if (wv['active'] != true) throw ApiException('err.warranty_expired', '${wv['days']}');
    if (wv['reason'] == 'open') _err('err.refix_open');
    if (wv['reason'] == 'limit') throw ApiException('err.refix_limit', '$maxRefix');
    final jid = _id('j'), bid = _id('b'), aid = _id('a');
    final n = DateTime.now();
    _t(d, 'jobs')[jid] = {
      'id': jid, 'customer_id': _me, 'lat': job['lat'], 'lng': job['lng'], 'address': job['address'], 'city': job['city'], 'locality': job['locality'],
      'start_date': '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}', 'status': 'assigned', 'created_at': _now(),
      'kind': 'single', 'refix': true,
      'items': [
        for (final t in _asgTrades(d, a).toSet())
          {'id': _id('w'), 'trade': t, 'lang': 'en', 'text': {'en': 'Warranty re-fix: $why'}, 'transcript': null, 'photos': ph, 'audio': null}
      ],
    };
    _t(d, 'bids')[bid] = {'id': bid, 'job_id': jid, 'worker_id': a['worker_id'], 'price': 0, 'status': 'accepted', 'created_at': _now()};
    _t(d, 'assignments')[aid] = {'id': aid, 'job_id': jid, 'worker_id': a['worker_id'], 'bid_id': bid, 'kind': 'refix', 'parent': a['id'],
      'refix_reason': why, 'nonce': _id('n')};
    final w = _user(d, a['worker_id'] as String);
    w['refixes'] = ((w['refixes'] as int?) ?? 0) + 1;
    _event(a, 'refix_requested', 'customer', note: why, photos: ph);
    _beginJourney(d, _row(d, 'assignments', aid)); // presentation helper (like payJob): he sets off at once
    await _save();
    return {'job_id': jid, 'assignment_id': aid};
  }

  // -- 2. share live trip
  @override
  Future<Json> shareTrip(String jobId) async {
    await _lag();
    final d = await _d;
    final j = _own(d, jobId);
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    final tr = _tracking(d, a);
    if (a['journey_started_at'] == null || a['started_at'] != null || tr == null || tr['arrived'] == true) _err('err.trip_not_active');
    final trips = (d['trips'] ??= <dynamic>[]) as List;
    var row = trips.cast<Map>().where((t) => t['assignment_id'] == a['id'] && DateTime.parse(t['expires_at'] as String).isAfter(DateTime.now())).firstOrNull;
    if (row == null) {
      final token = '${_id('t')}${_rnd.nextInt(1 << 30).toRadixString(36)}';
      row = {'token': token, 'assignment_id': a['id'], 'expires_at': DateTime.now().add(const Duration(hours: 6)).toIso8601String()};
      trips.add(row);
      await _save();
    }
    final w = _user(d, a['worker_id'] as String);
    final ph = (w['phone'] as String);
    final trades = _asgTrades(d, a);
    return {'token': row['token'], 'url': '$tripBase/${row['token']}', 'expires_at': row['expires_at'],
      'worker_name': w['name'], 'worker_phone_masked': ph.length >= 6 ? '${ph.substring(0, 2)}******${ph.substring(ph.length - 2)}' : '****',
      'trade': trades.isEmpty ? (j['items'] as List).cast<Map>().first['trade'] : trades.first, 'police_verified': w['police'] == 'verified'};
  }

  // -- 5. same-day pay: released escrow goes straight to UPI (L1 KYC) - otherwise it stays in the balance
  void _autoPayout(Json d, Json a, num amount) {
    if (amount <= 0) return;
    final w = _user(d, a['worker_id'] as String);
    if ((w['kyc'] as int) < 1 || w['upi'] == null || _kyc(w)['blocked_by_level2'] == true) return;
    (d['payouts'] as List).add({'id': _id('po'), 'worker_id': w['id'], 'amount': amount, 'upi': _maskUpi(w['upi'] as String), 'at': _now(),
      'source': 'auto', 'state': 'processing', 'assignment_id': a['id'], 'notified': false});
  }

  void _settlePayouts(Json d) {
    final now = DateTime.now();
    for (final p in (d['payouts'] as List).cast<Map>().where((p) => p['state'] == 'processing')) {
      if (now.difference(DateTime.parse(p['at'] as String)) >= payoutSettle) {
        p['state'] = 'paid';
        p['paid_at'] = _now();
      }
    }
  }

  @override
  Future<List<Json>> workerNotices() async {
    final d = await _d;
    _settlePayouts(d);
    await _save();
    return [
      for (final p in (d['payouts'] as List).cast<Map>().where((p) => p['worker_id'] == _me && p['source'] == 'auto' && p['notified'] != true))
        {'id': p['id'], 'kind': 'payout_sent', 'amount_inr': p['amount'], 'upi': p['upi'], 'state': p['state'] == 'processing' ? 'processing' : 'paid', 'at': p['at']}
    ];
  }

  @override
  Future<void> ackNotices(List<String> ids) async {
    final d = await _d;
    for (final p in (d['payouts'] as List).cast<Map>().where((p) => p['worker_id'] == _me && ids.contains(p['id']))) {
      p['notified'] = true;
    }
    await _save();
  }

  // -- 6. skill ladder + weekly streak
  Json _levelCard(Json u) => DemoLevels.view((u['completed'] as int?) ?? 0, ((u['rating_count'] as int?) ?? 0) > 0 ? (u['rating'] as num).toDouble() : 0.0,
      (u['refixes'] as int?) ?? 0);

  Json _streak(Json d, String workerId) {
    final weeks = <int>{
      for (final a in _all(d, 'assignments').where((a) => a['worker_id'] == workerId && a['kind'] != 'refix' && a['completed_at'] != null))
        DemoLevels.weekKey(DateTime.parse(a['completed_at'] as String).toLocal())
    };
    return DemoLevels.streakFromWeeks(weeks, DateTime.now());
  }

  // -- 10. hire again: a direct request is exclusive to one worker for 2 hours
  String? _directState(Json j) {
    if (j['direct_worker'] == null) return null;
    if (j['direct_declined'] == true) return 'declined';
    final u = _at(j['direct_until']);
    if (u != null && !DateTime.now().isBefore(u)) return 'expired';
    return 'pending';
  }

  String? _exclusiveTo(Json j) =>
      _directState(j) == 'pending' && (j['status'] == 'open' || j['status'] == 'bidding') ? j['direct_worker'] as String : null;

  void _checkDirect(Json j) {
    final ex = _exclusiveTo(j);
    if (ex != null && ex != _me) _err('err.direct_only');
  }

  Json? _directView(Json d, Json j) {
    final st = _directState(j);
    if (st == null) return null;
    final wid = j['direct_worker'] as String;
    final quoted = _all(d, 'bids').any((b) => b['job_id'] == j['id'] && b['worker_id'] == wid && b['status'] != 'withdrawn');
    return {'state': st, 'until': j['direct_until'], 'quoted': quoted, 'worker': _workerSummary(d, wid)};
  }

  @override
  Future<void> declineDirect(String jobId) async {
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    if (j['direct_worker'] != _me) _err('err.forbidden');
    if (_directState(j) == 'pending') j['direct_declined'] = true;
    await _save();
  }

  @override
  Future<List<Json>> favourites() async {
    await _lag();
    final d = await _d;
    final rows = (d['ratings'] as List).cast<Map>().where((r) =>
        r['direction'] == 'customer_to_worker' && r['is_auto'] != true && (r['overall'] as num) >= 4 &&
        _row(d, 'jobs', _row(d, 'assignments', r['assignment_id'] as String)['job_id'] as String)['customer_id'] == _me).toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    final out = <String, Json>{};
    for (final r in rows) {
      final a = _row(d, 'assignments', r['assignment_id'] as String);
      final w = _user(d, a['worker_id'] as String);
      if (w['suspended'] == true) continue;
      final j = _row(d, 'jobs', a['job_id'] as String);
      final row = out.putIfAbsent(w['id'] as String, () => {..._workerSummary(d, w['id'] as String), 'last_job_id': a['job_id'], 'jobs_together': 0,
        'last_trade': (j['items'] as List).cast<Map>().first['trade']});
      row['jobs_together'] = (row['jobs_together'] as int) + 1;
    }
    return out.values.toList();
  }

  @override
  Future<Json> rebookDraft({String? jobId, String? workerId}) async {
    await _lag();
    final d = await _d;
    Json? job;
    Json? worker;
    if (jobId != null) {
      job = _own(d, jobId);
      if (job['kind'] == 'team') _err('err.validation');
      final a = _asgOf(d, jobId).where((x) => x['kind'] != 'refix').firstOrNull;
      if (a != null) worker = _user(d, a['worker_id'] as String);
    } else if (workerId != null) {
      worker = _user(d, workerId);
      final mine = _all(d, 'jobs').where((j) => j['customer_id'] == _me && j['kind'] != 'team' && j['refix'] != true &&
          _asgOf(d, j['id'] as String).any((x) => x['worker_id'] == workerId && x['kind'] != 'refix')).toList()
        ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
      job = mine.firstOrNull;
    }
    if (worker == null || worker['role'] != 'worker') _err('err.not_found');
    job ??= (_all(d, 'jobs').where((j) => j['customer_id'] == _me).toList()..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String))).firstOrNull;
    final mineTrades = worker['trades'] as List;
    final items = <Json>[];
    if (job != null && job['kind'] != 'team') {
      for (final it in (job['items'] as List).cast<Map>()) {
        if (mineTrades.isNotEmpty && !mineTrades.contains(it['trade'])) continue;
        final i = it.cast<String, dynamic>();
        items.add({'trade': i['trade'], 'text_description': _text(i, i['lang'] as String) ?? '', 'description_language': i['lang']});
      }
    }
    if (items.isEmpty) {
      items.add({'trade': mineTrades.isEmpty ? 'helper' : mineTrades.first, 'text_description': '', 'description_language': _user(d)['lang']});
    }
    return {'worker': _workerSummary(d, worker['id'] as String), 'items': items, 'address_text': job?['address'] ?? '', 'lat': job?['lat'], 'lng': job?['lng'],
      'city': job?['city'] ?? '', 'locality': job?['locality'] ?? '', 'source_job_id': job?['id']};
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
      final r = (role == 'customer' || role == 'contractor') ? 'customer' : 'worker';
      final id = _id(r[0]);
      u = {'id': id, 'phone': phone, 'role': r, if (r == 'customer') 'ctype': role == 'contractor' ? 'contractor' : 'homeowner', 'name': null, 'lang': lang, 'kyc': 0, 'trades': <String>[], 'rating': 0.0,
        'rating_count': 0, 'completed': 0, 'badges': <String>[], 'lat': (d['anchor'] as Map?)?['lat'] ?? 18.52, 'lng': (d['anchor'] as Map?)?['lng'] ?? 73.85, 'online': true, 'earned': 0};
      _t(d, 'users')[id] = u;
      await _save();
    }
    _me = u['id'] as String;
    final user = SessionUser(id: _me!, phone: phone, role: u['role'] as String, language: lang, name: u['name'] as String?, kycLevel: u['kyc'] as int,
        customerType: u['ctype'] as String?, orgName: u['org'] as String?);
    return AuthResult('demo:$_me', user, '/${user.role}');
  }

  @override
  Future<SessionUser> setLanguage(String lang) async {
    final d = await _d;
    final u = _user(d)..['lang'] = lang;
    await _save();
    return SessionUser(id: u['id'] as String, phone: u['phone'] as String, role: u['role'] as String, language: lang,
        name: u['name'] as String?, kycLevel: u['kyc'] as int,
        customerType: u['ctype'] as String?, orgName: u['org'] as String?);
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
    final jobs = _all(d, 'jobs')
        .where((j) => j['status'] == 'open' || j['status'] == 'bidding' || (j['kind'] == 'team' && (j['status'] == 'assigned' || j['status'] == 'in_progress')))
        .toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    final directRows = <Json>[];
    for (final j in jobs) {
      final ex = _exclusiveTo(j);
      if (ex != null && ex != _me) continue; // "send to Ramesh first": nobody else sees it for 2 hours
      final trades = [for (final it in j['items'] as List) (it as Map)['trade'] as String];
      if ((me['trades'] as List).isNotEmpty && !trades.any((t) => (me['trades'] as List).contains(t))) continue;
      final tsum = _teamSummary(d, j);
      if (tsum != null &&
          !(tsum['items'] as List).cast<Map>().any((i) => (i['filled'] as int) < (i['headcount'] as int) && ((me['trades'] as List).isEmpty || (me['trades'] as List).contains(i['trade'])))) {
        continue; // every line this worker could fill is already full
      }
      final audio = [for (final it in j['items'] as List) if ((it as Map)['audio'] != null && it['muted'] != true) it['audio'] as Map];
      final mine = my[j['id']];
      (ex == _me ? directRows : out).add({
        'direct': ex == _me ? {'customer_name': _user(d, j['customer_id'] as String)['name'], 'until': j['direct_until']} : null,
        'id': j['id'], 'locality': j['locality'], 'trades': [for (final t in trades.toSet()) {'code': t}],
        'thumbnails': [for (final it in j['items'] as List) ...((it as Map)['photos'] as List)].take(4).toList(),
        'audio': audio.isEmpty ? null : {'count': audio.length, 'total_seconds': audio.fold<int>(0, (s, a) => s + (a['duration_sec'] as int)),
          'total_kb': audio.fold<int>(0, (s, a) => s + (a['size_kb'] as int))},
        'work_count': (j['items'] as List).length, 'distance_km': double.parse(_dist(me, j).toStringAsFixed(1)),
        'posted_at': j['created_at'], 'start_date': j['start_date'], 'already_bid': mine != null, 'my_price_inr': mine?['price'],
        'kind': j['kind'] ?? 'single', 'team': tsum, 'scheduled_for': j['scheduled_for'], 'time_slot': j['time_slot'],
      });
    }
    await _save();
    return [...directRows, ...out]; // direct requests ("Ramesh, Priya wants you again") always first
  }

  @override
  Future<Json> workerJob(String id) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', id);
    final me = _user(d);
    _checkDirect(j);
    final lvl = _levelOf(me), mult = (lvl['fair_multiplier'] as num).toDouble();
    final mine = _all(d, 'bids').where((b) => b['job_id'] == id && b['worker_id'] == _me).firstOrNull;
    final items = j['items'] as List;
    final isTeam = j['kind'] == 'team';
    final myTrades = me['trades'] as List;
    final myItem = !isTeam ? null : (items.cast<Map>().where((it) => myTrades.isEmpty || myTrades.contains(it['trade'])).firstOrNull ?? items.first as Map);
    final dw = myItem == null ? null : DemoPricing.dayWageRange(myItem['trade'] as String, _cityOf(d, j));
    return {
      ..._jobCard(j), 'address': mine?['status'] == 'accepted' ? j['address'] : j['locality'],
      'distance_km': double.parse(_dist(me, j).toStringAsFixed(1)),
      'work_items': [for (var i = 0; i < items.length; i++) _item((items[i] as Map).cast<String, dynamic>(), i, _lang)],
      'my_bid': mine == null ? null : {'id': mine['id'], 'price_inr': mine['price'], 'status': mine['status']},
      'bid_count': _all(d, 'bids').where((b) => b['job_id'] == id).length,
      'fair_range': dw != null
          ? DemoPricing.scaleRange({'low': dw['low'], 'median': dw['median'], 'high': dw['high'], 'min_wage_total': dw['min_wage'], 'est_days': 1}, mult)
          : DemoPricing.fairRange(_pricingItems(j), _cityOf(d, j), myTrades, mult),
      'level': lvl['code'], 'level_multiplier': mult,
      'direct': j['direct_worker'] == _me
          ? {'customer_name': _user(d, j['customer_id'] as String)['name'], 'until': j['direct_until'], 'state': _directState(j)}
          : null,
      if (myItem != null) ...{
        'my_item': {'trade': myItem['trade'], 'days': myItem['days'] ?? 1, 'daily_wage_inr': myItem['wage'], 'headcount': myItem['headcount'] ?? 1},
        'open_for_team': const ['open', 'bidding', 'assigned', 'in_progress'].contains(j['status']) && _openSlots(d, j) > 0,
      },
    };
  }

  @override
  Future<Json> placeBid(String jobId, int priceInr, String clientRef) async {
    await _lag();
    final d = await _d;
    final dup = _all(d, 'bids').where((b) => b['client_ref'] == clientRef).firstOrNull;
    if (dup != null) return {'id': dup['id'], 'status': dup['status'], 'price_inr': dup['price']};
    final j = _row(d, 'jobs', jobId);
    _checkDirect(j);
    final isTeam = j['kind'] == 'team';
    if (!(j['status'] == 'open' || j['status'] == 'bidding') && !(isTeam && (j['status'] == 'assigned' || j['status'] == 'in_progress') && _openSlots(d, j) > 0)) {
      _err('err.job_closed');
    }
    if (priceInr < 100 || priceInr > 10000000) _err('err.validation'); // zero / negative / absurd prices
    Map? teamItem;
    if (isTeam) {
      final mine = (_user(d)['trades'] as List);
      final cands = (j['items'] as List).cast<Map>().where((it) => mine.isEmpty || mine.contains(it['trade'])).toList();
      if (cands.isEmpty) _err('err.trade_mismatch');
      teamItem = cands.where((it) => _filled(d, it['id'] as String) < ((it['headcount'] as int?) ?? 1)).firstOrNull ?? _err('err.team_full');
    }
    var b = _all(d, 'bids').where((b) => b['job_id'] == jobId && b['worker_id'] == _me).firstOrNull;
    if (b != null && b['status'] == 'pending') {
      b['price'] = priceInr;
    } else if (b != null) {
      _err('err.bid_exists');
    } else {
      final id = _id('b');
      b = {'id': id, 'job_id': jobId, 'worker_id': _me, 'price': priceInr, 'status': 'pending', 'created_at': _now(),
        'client_ref': clientRef, 'sim_accept': !isTeam && j['sim_customer'] == true, if (teamItem != null) 'item_id': teamItem['id']};
      _t(d, 'bids')[id] = b;
      if (j['status'] == 'open') j['status'] = 'bidding';
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
      final a = _all(d, 'assignments').where((a) => a['bid_id'] == b['id'] && a['released_at'] == null).firstOrNull;
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
    if (b['worker_id'] != _me) _err('err.not_found');
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
      for (final a in _all(d, 'assignments').where((a) => a['worker_id'] == _me && a['released_at'] == null))
        {
          ..._assignmentView(d, a, viewer: 'worker'),
          'job': {..._jobCard(_row(d, 'jobs', a['job_id'] as String)), 'address': _row(d, 'jobs', a['job_id'] as String)['address']},
          'customer_name': _user(d, _row(d, 'jobs', a['job_id'] as String)['customer_id'] as String)['name'],
        }
    ]..sort((x, y) => ((y['job'] as Json)['created_at'] as String).compareTo((x['job'] as Json)['created_at'] as String));
  }

  /// Work really begins (code already checked or not needed): job -> in progress.
  void _startNow(Json d, Json a) {
    final j = _row(d, 'jobs', a['job_id'] as String);
    if (j['status'] == 'assigned') j['status'] = 'in_progress';
    a['started_at'] ??= _now();
  }

  @override
  Future<void> startWork(String assignmentId, {String? code}) async {
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    if (a['worker_id'] != _me) _err('err.not_found');
    _requirePaid(d, a);
    if (_codeRequired(d, a)) {
      if (code == null || code.trim().isEmpty) _err('err.start_code_required');
      try {
        _verifyCode(a, code, null);
      } on ApiException {
        await _save(); // the wrong try is counted even though the call fails
        rethrow;
      }
    }
    // an earlier offline check-in that was only "pending" is verified now
    for (final x in (d['attendance'] as List).cast<Map>().where((x) => x['assignment_id'] == a['id'] && (x['code_status'] == 'pending' || x['code_status'] == 'failed'))) {
      if (a['item_id'] == null || _sameDay(DateTime.parse(x['in'] as String).toLocal(), DateTime.now())) x['code_status'] = 'verified';
    }
    _startNow(d, a);
    await _save();
  }

  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Future<Json> attendance(Json body) async {
    await _lag();
    final d = await _d;
    final list = d['attendance'] as List;
    final dup = list.cast<Map>().where((x) => x['client_ref'] == body['client_ref']).firstOrNull;
    if (dup != null) return {'geofence_ok': dup['geofence_ok'], 'code_status': dup['code_status'] ?? 'not_required'};
    final a = _row(d, 'assignments', body['assignment_id'] as String);
    _requirePaid(d, a);
    final j = _row(d, 'jobs', a['job_id'] as String);
    final ok = _dist({'lat': body['lat'], 'lng': body['lng']}, j) * 1000 <= 300;
    var codeStatus = 'not_required';
    if (body['kind'] == 'in') {
      final at = body['at'] == null ? null : DateTime.tryParse('${body['at']}');
      final code = body['start_code'] as String?;
      if (_codeRequired(d, a, at)) {
        if (body['offline'] == true) {
          // typed without a connection: verified when it syncs (same attempt counting); a wrong one never starts the work
          codeStatus = (code == null || code.isEmpty) ? 'pending' : (_verifyCode(a, code, at, strict: false) ? 'verified' : 'failed');
        } else {
          if (code == null || code.isEmpty) _err('err.start_code_required');
          try {
            _verifyCode(a, code, at);
          } on ApiException {
            await _save();
            rethrow;
          }
          codeStatus = 'verified';
        }
      }
      list.add({'assignment_id': a['id'], 'in': body['at'] ?? _now(), 'out': null, 'offline': body['offline'] == true,
        'geofence_ok': ok, 'client_ref': body['client_ref'], 'selfie': body['selfie_key'], 'code_status': codeStatus});
      if (codeStatus == 'verified' || codeStatus == 'not_required') _startNow(d, a);
    } else {
      final open = list.cast<Map>().where((x) => x['assignment_id'] == a['id'] && x['out'] == null).lastOrNull;
      if (open == null) _err('err.not_checked_in');
      open['out'] = body['at'] ?? _now();
      open['geofence_ok'] = open['geofence_ok'] == true && ok;
    }
    await _save();
    return {'geofence_ok': ok, 'code_status': codeStatus};
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
  Future<void> markDone(String assignmentId, {List<String> photos = const [], String? note}) async {
    await _lag();
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    if (a['worker_id'] != _me) _err('err.not_found');
    if (_user(d)['suspended'] == true) _err('err.account_suspended');
    _sweepAuto(d);
    if (a['released_at'] != null) _err('err.hire_cancelled');
    final j = _row(d, 'jobs', a['job_id'] as String);
    if (j['status'] == 'completed' || (a['worker_done_at'] != null && a['rework_open'] != true && j['status'] == 'in_progress')) return; // idempotent
    if (j['status'] == 'disputed') _err('err.job_disputed');
    if (!(j['status'] == 'assigned' || j['status'] == 'in_progress')) _err('err.job_closed');
    final proof = [for (final p in photos) if (p.trim().isNotEmpty) p.trim()];
    if (proof.length > 5) _err('err.too_many_photos');
    if (proof.isEmpty) _err('err.proof_required');
    final n = note?.trim();
    if (n != null && n.length > 1000) _err('err.validation');
    _requirePaid(d, a); // nobody finishes (or starts) before the money is held
    if (_codeRequired(d, a)) _err('err.start_code_required'); // the customer's code proves he really arrived
    _startNow(d, a);
    a['worker_done_at'] = _now();
    a['proof'] = proof;
    a['done_note'] = (n == null || n.isEmpty) ? null : n;
    a['rework_open'] = false;
    _event(a, 'worker_done', 'worker', note: a['done_note'] as String?, photos: proof);
    await _save();
  }

  @override
  Future<void> workerDispute(String assignmentId, String reason) async {
    await _lag();
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    if (a['worker_id'] != _me) _err('err.not_found');
    _sweepAuto(d);
    if (a['released_at'] != null) _err('err.hire_cancelled');
    _openDispute(d, a, reason, 'worker');
    await _save();
  }

  @override
  Future<Json> withdrawHire(String assignmentId) async {
    await _lag();
    final d = await _d;
    final a = _row(d, 'assignments', assignmentId);
    if (a['worker_id'] != _me) _err('err.not_found');
    final out = _releaseHire(d, a, 'worker_withdrew', reopen: true);
    await _save();
    return out;
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
    final todays = <Json>[];
    final nowT = DateTime.now();
    for (final p in (d['payouts'] as List).cast<Map>().where((p) => p['worker_id'] == _me)) {
      final st = p['state'] == 'processing' ? 'processing' : 'paid';
      rows.add({'kind': 'payout', 'amount_inr': p['amount'], 'state': st, 'date': p['at'], 'upi': p['upi'], 'source': p['source'] ?? 'withdraw'});
      if (p['source'] == 'auto' && _sameDay(DateTime.parse(p['at'] as String).toLocal(), nowT)) {
        final pa = p['assignment_id'] == null ? null : _row(d, 'assignments', p['assignment_id'] as String);
        final pj = pa == null ? null : _row(d, 'jobs', pa['job_id'] as String);
        todays.add({'id': p['id'], 'amount_inr': p['amount'], 'upi': p['upi'], 'state': st, 'source': 'auto', 'at': p['at'], 'paid_at': p['paid_at'],
          'locality': pj?['locality'], 'trades': pj == null ? <String>[] : [for (final it in pj['items'] as List) (it as Map)['trade']].toSet().toList()});
      }
    }
    rows.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    await _save();
    return {'available_inr': bal['available'], 'held_inr': bal['held'], 'total_earned_inr': bal['released'], 'paid_out_inr': bal['paid'],
      'upi': _maskUpi(u['upi'] as String?), 'kyc': _kyc(u), 'history': rows,
      'paid_today': {'total_inr': todays.fold<num>(0, (s, x) => s + (x['amount_inr'] as num)), 'items': todays},
      'nudge_add_upi': (bal['available'] as num) > 0 && u['upi'] == null};
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
    (d['payouts'] as List).add({'id': _id('po'), 'worker_id': _me, 'amount': bal, 'upi': _maskUpi(u['upi'] as String), 'at': _now(), 'source': 'withdraw', 'state': 'paid'});
    await _save();
    return {'amount_inr': bal, 'upi': _maskUpi(u['upi'] as String), 'ref': 'payout_demo'};
  }

  Json _breakdown(Json d, String wid) {
    final rs = (d['ratings'] as List).cast<Map>().where((r) => r['ratee'] == wid && r['direction'] == 'customer_to_worker' && r['is_auto'] != true).toList();
    final u = _user(d, wid);
    double avg(String k) => rs.isEmpty ? (u['rating'] as num).toDouble() : rs.fold<num>(0, (s, r) => s + (r[k] as num)) / rs.length;
    double r1(double v) => double.parse(v.toStringAsFixed(1));
    return {'quality': r1(avg('quality')), 'timeliness': r1(avg('timeliness')), 'behaviour': r1(avg('behaviour')),
      'value_for_money': r1(avg('value_for_money')), 'overall': r1((u['rating'] as num).toDouble()), 'count': u['rating_count']};
  }

  List<Json> _history(Json d, String wid) {
    final out = <Json>[];
    for (final r in (d['ratings'] as List).cast<Map>().where((r) => r['ratee'] == wid && r['direction'] == 'customer_to_worker' && r['is_auto'] != true)) {
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
      'breakdown': _breakdown(d, _me!), 'history': _history(d, _me!), 'kyc': _kyc(u), 'eshram_registered': u['eshram'] == true, 'strikes': (u['strikes'] as int?) ?? 0,
      'level_card': _levelCard(u), 'streak': _streak(d, _me!), 'warranty_record': _warrantyRecord(u),
      'police': {'status': (u['police'] as String?) ?? 'none', 'note': u['police_note'], 'requested_at': u['police_requested_at']}};
  }

  @override
  Future<Json> labourCard() async {
    final d = await _d;
    final u = _user(d);
    final b = _breakdown(d, _me!);
    return {'name': u['name'], 'trades': u['trades'], 'rating': b['overall'], 'rating_count': b['count'], 'completed_jobs': u['completed'],
      'badges': u['badges'], 'breakdown': b, 'verified_level': u['kyc'], 'police_verified': u['police'] == 'verified', 'level': _levelOf(u)['code'], 'eshram_registered': u['eshram'] == true, 'city': (d['city'] as String?) ?? '',
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

  /// The sample data is seeded around Pune (any Indian city works as the target). The first time we learn where the user really is, we
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
      // City drives the price tier: nearest known city now, the phone's geocoder refines it below.
      final city = DemoPricing.cityNear(lat, lng) ?? '';
      d['city'] = city;
      for (final j in _all(d, 'jobs').where((j) => j['sim'] != true)) {
        j['city'] = city;
      }
      await _save();
      // Rename sample areas to real nearby place names (best effort, in the background).
      () async {
        final seen = <String, String>{};
        for (final j in _all(d, 'jobs').where((j) => j['sim'] != true && !(j['id'] as String).startsWith('hj')).toList()) {
          final a = await LocationService.address((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble());
          if (a == null) continue;
          if (a.city.isNotEmpty) {
            d['city'] = a.city;
            j['city'] = a.city;
          }
          if (a.area.isEmpty) continue;
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
      final row = <String, dynamic>{..._jobCard(j), 'bid_count': _all(d, 'bids').where((b) => b['job_id'] == j['id'] && b['status'] != 'withdrawn').length,
        'needs_rating': j['status'] == 'completed' && p?['state'] == 'held', 'worker_name': a == null ? null : _user(d, a['worker_id'] as String)['name'],
        'payment_state': p?['state'],
        'needs_action': a != null && j['status'] == 'in_progress' && a['worker_done_at'] != null && a['rework_open'] != true,
        'rework_open': a != null && a['rework_open'] == true, 'auto_confirm_at': a == null ? null : _autoConfirmAt(a)?.toIso8601String(),
        'no_quotes_24h': _noQuotes24h(d, j), 'refix': a != null && a['kind'] == 'refix', 'direct_state': _directState(j),
        'direct_until': j['direct_until'], 'direct_worker': j['direct_worker'] == null ? null : _user(d, j['direct_worker'] as String)['name'],
        'hire_again_worker_id': a != null && j['kind'] != 'team' && a['kind'] != 'refix' ? a['worker_id'] : null,
        'warranty': a != null && j['kind'] != 'team' ? _warrantyView(d, a) : null};
      if (j['kind'] == 'team') {
        final ros = _roster(d, j);
        row.addAll({'needs_rating': false, 'worker_name': null, 'payment_due_inr': ros['payment_due_inr'],
          'payment_state': (ros['payment_due_count'] as int) > 0 ? 'created' : p?['state'],
          'to_settle': (ros['workers'] as List).cast<Map>().where((w) => w['settled'] != true && (w['payment'] as Map?)?['escrow_state'] == 'held' &&
              (w['days_worked'] as int) >= (w['days_planned'] as int)).length});
      }
      out.add(row);
    }
    await _save();
    return out;
  }

  bool _noQuotes24h(Json d, Json j) {
    if (!(j['status'] == 'open' || j['status'] == 'bidding')) return false;
    if (DateTime.now().difference(DateTime.parse(j['created_at'] as String)) < const Duration(hours: 24)) return false;
    return !_all(d, 'bids').any((b) => b['job_id'] == j['id'] && b['status'] == 'pending');
  }

  /// Same model as the backend. Extra optional [texts] (aligned with [trades]) and [city] improve the
  /// estimate; without a city the sample marketplace's current city is used.
  @override
  Future<Json> priceEstimate(List<String> trades, String? locality, {List<String?>? texts, String? city}) async {
    await _lag();
    final d = await _d;
    final c = city ?? (d['city'] as String?) ?? '';
    final pairs = <(String, String?)>[
      for (var i = 0; i < trades.length; i++)
        if (DemoPricing.tradeSkill.containsKey(trades[i])) (trades[i], texts != null && i < texts.length ? texts[i] : null)
    ];
    final est = DemoPricing.estimateItems(pairs, c);
    final items = [
      for (final it in (est['items'] as List).cast<Map<String, dynamic>>())
        {...it, 'samples': 9 + _rnd.nextInt(6), 'scope': 'locality', 'city': c, 'city_multiplier': DemoPricing.cityMultiplier(c)}
    ];
    return {'items': items, 'total_low_inr': est['total_low_inr'], 'total_median_inr': est['total_median_inr'],
      'total_high_inr': est['total_high_inr'], 'city': c, 'platform_fee_inr': fee};
  }

  @override
  Future<Json> createJob(Json body) async {
    await _lag();
    final items = body['work_items'] as List;
    if (items.isEmpty) _err('err.no_work_items');
    final sd = DateTime.tryParse('${body['start_date']}');
    if (sd != null) {
      final n = DateTime.now(), today = DateTime(n.year, n.month, n.day), day = DateTime(sd.year, sd.month, sd.day);
      if (day.isBefore(today)) _err('err.date_in_past');
      if (day.isAfter(today.add(const Duration(days: 365)))) _err('err.date_too_far');
    }
    final d = await _d;
    final isTeam = body['kind'] == 'team';
    if (isTeam && _user(d)['ctype'] != 'contractor') _err('err.contractor_only');
    _validateSchedule(body);
    for (final w in items.cast<Map>()) {
      if ((w['photo_keys'] as List).length < 2) _err('err.photos_required');
      if (((w['text_description'] as String?) ?? '').trim().length < 50) _err('err.description_short');
      if (isTeam && ((w['daily_wage_inr'] as num?) ?? 0) < DemoPricing.minWagePerDay(w['trade'] as String)) _err('err.wage_below_minimum');
    }
    if (isTeam && items.cast<Map>().map((w) => w['trade']).toSet().length != items.length) _err('err.validation');
    final id = _id('j');
    final directId = body['direct_worker_id'] as String?;
    if (directId != null) {
      final w = _t(d, 'users')[directId] as Map?;
      if (w == null || w['role'] != 'worker' || w['suspended'] == true || isTeam) _err('err.validation');
      final mine = w['trades'] as List;
      if (mine.isNotEmpty && !items.cast<Map>().any((it) => mine.contains(it['trade']))) _err('err.trade_mismatch');
    }
    final bodyCity = (body['city'] as String?)?.trim() ?? '';
    final jobCity = bodyCity.isNotEmpty
        ? bodyCity
        : DemoPricing.cityNear((body['location_lat'] as num).toDouble(), (body['location_lng'] as num).toDouble()) ?? (d['city'] as String?) ?? '';
    _t(d, 'jobs')[id] = {
      'id': id, 'customer_id': _me, 'lat': body['location_lat'], 'lng': body['location_lng'], 'address': body['address_text'],
      'city': jobCity, 'locality': body['locality'] ?? jobCity, 'start_date': body['start_date'], 'status': 'open', 'created_at': _now(), 'sim': true,
      'kind': isTeam ? 'team' : 'single', 'scheduled_for': body['scheduled_for'], 'time_slot': body['time_slot'],
      if (directId != null) ...{
        'direct_worker': directId, 'direct_declined': false,
        'direct_until': DateTime.now().add(const Duration(hours: directHours)).toIso8601String(),
      },
      'items': [
        for (final w in items.cast<Map>())
          {
            'id': _id('w'), 'trade': w['trade'], 'lang': w['description_language'],
            if (isTeam) ...{'headcount': w['headcount'] ?? 1, 'days': w['days'] ?? 1, 'wage': w['daily_wage_inr']},
            'text': {if (w['text_description'] != null) w['description_language']: w['text_description']},
            'transcript': w['transcript'] == null ? null : {w['description_language']: w['transcript']},
            'photos': w['photo_keys'],
            'audio': w['audio_key'] == null ? null : {'url': w['audio_key'], 'duration_sec': w['audio_duration_sec'], 'size_kb': ((w['audio_size_bytes'] ?? 0) as int) ~/ 1024},
          }
      ],
    };
    await _save();
    return {'id': id, 'status': 'open', if (directId != null) 'direct_until': (_row(d, 'jobs', id))['direct_until']};
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
    final isTeam = j['kind'] == 'team';
    final a = isTeam ? null : _assignmentFor(d, id);
    await _save();
    Json teamBid(Json b) {
      final it = (items.cast<Map>()).where((x) => x['id'] == b['item_id']).firstOrNull;
      return {'trade': it?['trade'], 'work_item_id': it?['id'], 'daily_wage_inr': b['price'], 'days': it?['days'] ?? 1,
        'min_wage': it == null ? null : DemoPricing.minWagePerDay(it['trade'] as String)};
    }
    return {
      ..._jobCard(j),
      'work_items': [for (var i = 0; i < items.length; i++) _item((items[i] as Map).cast<String, dynamic>(), i, _lang)],
      'bids': [
        for (final b in bids)
          {'id': b['id'], 'price_inr': b['price'], 'status': b['status'], 'created_at': b['created_at'], 'worker': _workerSummary(d, b['worker_id'] as String),
            if (isTeam) ...teamBid(b),
            'warranty_days': _warrantyDays(_quoteTrades(d, j, b['worker_id'] as String)),
            'fair': DemoPricing.fairCheck(b['price'] as num, _pricingItems(j), _cityOf(d, j), _user(d, b['worker_id'] as String)['trades'] as List,
                (_levelOf(_user(d, b['worker_id'] as String))['fair_multiplier'] as num).toDouble())}
      ],
      'direct': _directView(d, j),
      'assignment': a == null ? null : _assignmentView(d, a, viewer: 'customer'), 'fee_inr': fee,
      'no_quotes_24h': _noQuotes24h(d, j), 'nudged_at': j['nudged_at'],
      if (isTeam) 'team': _roster(d, j),
    };
  }

  @override
  Future<Json> acceptBid(String jobId, String bidId) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    final b = _row(d, 'bids', bidId);
    if (j['customer_id'] != _me) _err('err.not_your_job');
    if (b['job_id'] != jobId) _err('err.not_found');
    if (b['status'] != 'pending') _err('err.job_closed');
    if (j['kind'] == 'team') {
      final a = _acceptTeam(d, j, b);
      await _save();
      return {'assignment_id': a['id']};
    }
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
    if (j['kind'] == 'team') {
      // ONE checkout for the whole team: every unpaid worker's escrow is funded.
      num paid = 0;
      var n = 0;
      for (final ta in _asgOf(d, jobId)) {
        final tp = _paymentFor(d, ta['id'] as String);
        if (tp != null && tp['state'] == 'created') {
          tp['state'] = 'held';
          tp['method'] = method;
          tp['paid_at'] = _now();
          ta['nonce'] = _id('n');
          paid += tp['amount'] as num;
          n++;
        }
      }
      await _save();
      return {'paid_inr': paid, 'count': n, 'method': method, 'amount_inr': paid, 'platform_fee_inr': fee * n, 'worker_payout_inr': paid - fee * n,
        'refund_inr': 0, 'escrow_state': 'held', 'released_at': null, 'ref': 'BC-TEAM-${jobId.toUpperCase()}', 'paid_at': _now()};
    }
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled'); // a stale payment page after a cancel / change of worker
    final p = _paymentFor(d, a['id'] as String) ?? _err('err.hire_cancelled');
    if (p['state'] == 'created' && j['status'] != 'assigned') _err('err.job_closed');
    if (p['state'] == 'created') {
      p['state'] = 'held';
      p['method'] = method;
      p['paid_at'] = _now();
      a['nonce'] = _id('n'); // the customer now sees the 4-digit start code
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
    final j = _own(d, jobId);
    if (j['kind'] == 'team') _err('err.team_use_roster');
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    _sweepAuto(d); // the 48 h rule applies before the customer's action is evaluated
    if (j['status'] == 'completed') return; // idempotent
    if (j['status'] == 'disputed') _err('err.job_disputed');
    if (!(j['status'] == 'assigned' || j['status'] == 'in_progress')) _err('err.job_closed');
    _requirePaid(d, a);
    j['status'] = 'completed';
    a['started_at'] ??= _now();
    a['completed_at'] ??= _now();
    a['rework_open'] = false;
    _event(a, 'confirmed', 'customer');
    await _save();
  }

  @override
  Future<Json> sendBack(String jobId, {required List<String> reasons, String? note, List<String> photos = const []}) async {
    await _lag();
    final d = await _d;
    final j = _own(d, jobId);
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    _sweepAuto(d);
    if (j['status'] == 'disputed') _err('err.job_disputed');
    if (j['status'] != 'in_progress' || a['worker_done_at'] == null || a['rework_open'] == true) _err('err.nothing_to_send_back');
    final rs = reasons.toSet().toList();
    if (rs.isEmpty || rs.any((r) => !_reworkReasons.contains(r))) _err('err.validation');
    final n = note?.trim();
    if (n != null && n.length > 1000) _err('err.validation');
    if (photos.length > 5) _err('err.too_many_photos');
    final noteOrNull = (n == null || n.isEmpty) ? null : n;
    _event(a, 'rework_requested', 'customer', reasons: rs, note: noteOrNull, photos: photos);
    final rounds = (a['rework_count'] as int?) ?? 0;
    Json out;
    if (rounds >= _maxRework) {
      // 3rd disagreement: no more ping-pong. Support decides; the money stays frozen in escrow.
      final dsp = _openDispute(d, a, 'Auto-opened after ${_maxRework + 1} disagreements. Customer says: ${rs.join(', ')}. ${noteOrNull ?? ''}', 'customer', auto: true);
      out = {'outcome': 'disputed', 'dispute_id': dsp['id'], 'rework_count': rounds};
    } else {
      a['rework_count'] = rounds + 1;
      a['rework_open'] = true;
      a['worker_done_at'] = null; // the worker must finish again, with new proof
      out = {'outcome': 'rework', 'rework_count': rounds + 1, 'rework_left': _maxRework - rounds - 1};
    }
    await _save();
    return out;
  }

  @override
  Future<Json> rateWorker(String jobId, Json stars) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    if (j['status'] != 'completed') _err('err.job_not_completed');
    final a = _assignmentFor(d, jobId) ?? _err('err.not_found');
    if (a['kind'] == 'refix') _err('err.validation'); // nothing to rate or pay on a free re-fix visit
    final rs = d['ratings'] as List;
    if (rs.cast<Map>().any((r) => r['assignment_id'] == a['id'] && r['direction'] == 'customer_to_worker')) _err('err.already_rated');
    final p = _paymentFor(d, a['id'] as String);
    if (p == null || p['state'] != 'held') _err('err.payment_pending');
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
    p['state'] = 'released';
    p['released_at'] = _now();
    w['earned'] = ((w['earned'] as num?) ?? 0) + (p['payout'] as num);
    _autoPayout(d, a, p['payout'] as num); // same-day pay: straight to UPI when there is one
    await _save();
    return {'overall': overall, 'payment': _paymentView(p)};
  }

  @override
  Future<Json> cancelJob(String jobId) async {
    final d = await _d;
    final j = _own(d, jobId);
    if (j['status'] == 'cancelled') return {'status': 'cancelled', 'refunded_inr': 0};
    if (j['status'] == 'open' || j['status'] == 'bidding') {
      j['status'] = 'cancelled';
      for (final b in _all(d, 'bids').where((b) => b['job_id'] == jobId && b['status'] == 'pending')) {
        b['status'] = 'rejected';
      }
      await _save();
      return {'status': 'cancelled', 'refunded_inr': 0};
    }
    final a = _assignmentFor(d, jobId);
    if (j['status'] == 'assigned' && a != null) {
      final out = _releaseHire(d, a, 'cancelled', reopen: false);
      await _save();
      return out;
    }
    _err(j['status'] == 'in_progress' ? 'err.job_started_dispute' : 'err.job_closed');
  }

  @override
  Future<Json> reopenJob(String jobId) async {
    await _lag();
    final d = await _d;
    final j = _own(d, jobId);
    final a = _assignmentFor(d, jobId);
    if (a == null) {
      if (j['status'] == 'open' || j['status'] == 'bidding') return {'status': j['status'], 'refunded_inr': 0};
      _err('err.job_closed');
    }
    final out = _releaseHire(d, a, 'customer_changed', reopen: true);
    await _save();
    return out;
  }

  @override
  Future<Json> reportNoShow(String jobId) async {
    await _lag();
    final d = await _d;
    _own(d, jobId);
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    if (a['started_at'] != null || a['worker_done_at'] != null) _err('err.job_started');
    final due = _noShowAfter(d, a);
    if (due == null || DateTime.now().isBefore(due)) {
      throw ApiException('err.no_show_too_early', '${due == null ? 60 : max(1, due.difference(DateTime.now()).inMinutes + 1)}');
    }
    final out = _releaseHire(d, a, 'no_show', reopen: true);
    await _save();
    return out;
  }

  @override
  Future<void> nudgeJob(String jobId) async {
    final d = await _d;
    final j = _own(d, jobId);
    if (!(j['status'] == 'open' || j['status'] == 'bidding')) _err('err.job_closed');
    final last = _at(j['nudged_at']);
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 6)) _err('err.nudge_too_soon');
    j['nudged_at'] = _now();
    await _save();
  }

  @override
  Future<void> dispute(String jobId, String reason) async {
    final d = await _d;
    _own(d, jobId);
    final a = _assignmentFor(d, jobId) ?? _err('err.hire_cancelled');
    _sweepAuto(d);
    _openDispute(d, a, reason, 'customer');
    await _save();
  }

  @override
  Future<List<Json>> payments() async {
    await _lag();
    final d = await _d;
    final out = <Json>[];
    for (final j in _all(d, 'jobs').where((j) => j['customer_id'] == _me)) {
      for (final a in _asgOf(d, j['id'] as String)) {
        final p = _paymentFor(d, a['id'] as String);
        if (p == null) continue;
        final wv = _warrantyView(d, a);
        out.add({..._paymentView(p), 'job_id': j['id'], 'locality': j['locality'], 'worker_name': _user(d, a['worker_id'] as String)['name'],
          'warranty_days': wv?['days'] ?? 0, 'warranty_until': wv?['until'],
          'trades': [for (final it in j['items'] as List) (it as Map)['trade']].toSet().toList(), 'created_at': j['created_at']});
      }
    }
    out.sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    return out;
  }

  @override
  Future<List<Json>> browseWorkers(String? trade) async {
    await _lag();
    final d = await _d;
    final ws = _all(d, 'users').where((u) => u['role'] == 'worker' && (u['kyc'] as int) >= 1 && (trade == null || (u['trades'] as List).contains(trade))).toList()
      ..sort((a, b) {
        // best rated first (to 1 decimal); at equal rating the police-verified worker ranks higher ("Verified first")
        final c = double.parse((b['rating'] as num).toStringAsFixed(1)).compareTo(double.parse((a['rating'] as num).toStringAsFixed(1)));
        if (c != 0) return c;
        final v = (b['police'] == 'verified' ? 1 : 0).compareTo(a['police'] == 'verified' ? 1 : 0);
        return v != 0 ? v : (b['rating_count'] as int).compareTo(a['rating_count'] as int);
      });
    return [for (final w in ws) {..._workerSummary(d, w['id'] as String), 'online': w['online']}];
  }

  @override
  Future<Json> workerPublic(String workerId) async {
    await _lag();
    final d = await _d;
    final u = _user(d, workerId);
    return {..._workerSummary(d, workerId), 'breakdown': _breakdown(d, workerId), 'history': _history(d, workerId),
      'warranty_record': _warrantyRecord(u), 'level_card': _levelCard(u), 'streak': _streak(d, workerId)};
  }

  // ---------------------------------------------------------------- contractor / team hiring
  @override
  Future<Json> wageSuggestion(List<String> trades, String? city) async {
    await _lag();
    final d = await _d;
    final c = (city != null && city.isNotEmpty) ? city : (d['city'] as String?) ?? '';
    return {'city': c, 'items': [for (final t in trades.toSet()) if (DemoPricing.tradeSkill.containsKey(t)) DemoPricing.dayWageRange(t, c)]};
  }

  @override
  Future<Json> teamRoster(String jobId) async {
    await _lag();
    final d = await _d;
    _simulate(d);
    final j = _row(d, 'jobs', jobId);
    if (j['customer_id'] != _me || j['kind'] != 'team') _err('err.not_found');
    await _save();
    return _roster(d, j);
  }

  @override
  Future<Json> settleTeamWorker(String jobId, String assignmentId, Json stars) async {
    await _lag();
    final d = await _d;
    final j = _row(d, 'jobs', jobId);
    if (j['customer_id'] != _me) _err('err.not_your_job');
    final a = _row(d, 'assignments', assignmentId);
    if (a['job_id'] != jobId) _err('err.not_found');
    final p = _paymentFor(d, assignmentId) ?? _err('err.not_found');
    if (p['state'] != 'held') _err('err.payment_not_held');
    final rs = d['ratings'] as List;
    if (rs.cast<Map>().any((r) => r['assignment_id'] == assignmentId && r['direction'] == 'customer_to_worker')) _err('err.already_rated');
    final v = [stars['quality'], stars['timeliness'], stars['behaviour'], stars['value_for_money']].cast<int>();
    if (v.any((x) => x < 1 || x > 5)) _err('err.validation');
    final wage = _row(d, 'bids', a['bid_id'] as String)['price'] as num;
    final days = (a['days'] as int?) ?? 1, worked = _daysWorked(d, a);
    final overall = v.reduce((x, y) => x + y) / 4;
    rs.add({'assignment_id': assignmentId, 'direction': 'customer_to_worker', 'ratee': a['worker_id'], 'quality': v[0], 'timeliness': v[1],
      'behaviour': v[2], 'value_for_money': v[3], 'overall': overall, 'comment': stars['comment'], 'created_at': _now()});
    final w = _user(d, a['worker_id'] as String);
    if (worked > 0) {
      w['rating'] = double.parse((((w['rating'] as num) * (w['rating_count'] as int) + overall) / ((w['rating_count'] as int) + 1)).toStringAsFixed(2));
      w['rating_count'] = (w['rating_count'] as int) + 1;
      w['completed'] = (w['completed'] as int) + 1;
    }
    if (worked == 0) {
      // nobody turned up: everything goes back to the contractor
      p['refund'] = p['amount'];
      p['payout'] = 0;
      p['fee'] = 0;
      p['state'] = 'refunded';
    } else {
      p['refund'] = wage * (days - worked);
      p['payout'] = wage * worked;
      p['state'] = 'released';
      w['earned'] = ((w['earned'] as num?) ?? 0) + wage * worked;
      _autoPayout(d, a, wage * worked);
    }
    p['released_at'] = _now();
    a['completed_at'] = _now();
    final asg = _asgOf(d, jobId);
    if (asg.every((x) => const ['released', 'refunded', 'split'].contains(_paymentFor(d, x['id'] as String)?['state']))) {
      j['status'] = 'completed';
      for (final o in _all(d, 'bids').where((b) => b['job_id'] == jobId && b['status'] == 'pending')) {
        o['status'] = 'rejected';
      }
    } else if (j['status'] == 'assigned') {
      j['status'] = 'in_progress';
    }
    await _save();
    return {'days_worked': worked, 'days_planned': days, 'payout_inr': p['payout'], 'refund_inr': p['refund'], 'overall': overall};
  }

  @override
  Future<void> setBusinessName(String name) async {
    final d = await _d;
    _user(d)['org'] = name.trim();
    await _save();
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
    if (body.trim().isEmpty || body.length > 1000) _err('err.validation');
    final job = _row(d, 'jobs', jobId);
    final hired = _assignmentFor(d, jobId);
    final workerId = job['customer_id'] == _me ? to : _me;
    // Not hired (or job cancelled): the thread stays readable but read-only.
    if ((hired != null && hired['worker_id'] != workerId) || job['status'] == 'cancelled') _err('err.chat_closed');
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
        {List<String> trades = const [], double rating = 0, int count = 0, int kyc = 1, String loc = 'Kothrud', List<String> badges = const [], bool eshram = false,
        String? ctype, String? org}) {
      const ll = {'Kothrud': [18.5074, 73.8077], 'Baner': [18.559, 73.7868], 'Hadapsar': [18.5089, 73.926], 'Wakad': [18.5986, 73.7604],
        'Viman Nagar': [18.5679, 73.9143], 'Aundh': [18.558, 73.8075], 'Kharadi': [18.5515, 73.9348], 'Shivajinagar': [18.5308, 73.8475]};
      users[id] = {'id': id, 'phone': phone, 'role': role, 'name': name, 'lang': lang, 'kyc': kyc, 'trades': trades, 'rating': rating,
        'rating_count': count, 'completed': count, 'badges': badges, 'lat': ll[loc]![0], 'lng': ll[loc]![1], 'online': true,
        'earned': count * 2500, 'upi': kyc >= 1 ? '${name.split(' ').first.toLowerCase()}@okaxis' : null, 'eshram': eshram,
        'selfie': null, if (ctype != null) 'ctype': ctype, if (org != null) 'org': org};
    }

    user('a1', '9000000001', 'admin', 'Ops Admin', 'en', kyc: 2);
    user('c1', '9100000001', 'customer', 'Priya Sharma', 'hi', ctype: 'homeowner');
    user('c2', '9100000002', 'customer', 'Anil Deshmukh', 'mr', ctype: 'contractor', org: 'Deshmukh Constructions');
    user('c3', '9100000003', 'customer', 'Neha Kulkarni', 'en', ctype: 'homeowner');
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
    // More people from different states: every trade has at least two workers (21-24 are dedicated helpers / mazdoor).
    user('w11', '9200000011', 'worker', 'Ramkumar Verma', 'hi', trades: ['mason'], rating: 4.3, count: 14);
    user('w12', '9200000012', 'worker', 'Basavaraj Hiremath', 'kn', trades: ['mason', 'helper'], rating: 4.0, count: 7, loc: 'Hadapsar');
    user('w13', '9200000013', 'worker', 'Murugan S', 'ta', trades: ['plumber'], rating: 4.5, count: 22, loc: 'Aundh');
    user('w14', '9200000014', 'worker', 'Shamshad Alam', 'hi', trades: ['plumber'], rating: 4.2, count: 11, loc: 'Baner');
    user('w15', '9200000015', 'worker', 'Jignesh Patel', 'gu', trades: ['electrician'], rating: 4.4, count: 17);
    user('w16', '9200000016', 'worker', 'Shaji Thomas', 'ml', trades: ['electrician', 'helper'], rating: 4.6, count: 26, kyc: 2, loc: 'Wakad', badges: ['trusted_electrician'], eshram: true);
    user('w17', '9200000017', 'worker', 'Rajesh Suthar', 'hi', trades: ['carpenter'], rating: 4.3, count: 16, loc: 'Hadapsar');
    user('w18', '9200000018', 'worker', 'Bikash Nayak', 'or', trades: ['carpenter'], rating: 4.1, count: 10, loc: 'Baner');
    user('w19', '9200000019', 'worker', 'Dipak Das', 'as', trades: ['painter'], rating: 4.2, count: 12, loc: 'Wakad');
    user('w20', '9200000020', 'worker', 'Subhash Mondal', 'bn', trades: ['painter'], rating: 3.8, count: 6, loc: 'Viman Nagar');
    user('w21', '9200000021', 'worker', 'Manoj Mahto', 'hi', trades: ['helper'], rating: 4.0, count: 9);
    user('w22', '9200000022', 'worker', 'Raju Munda', 'hi', trades: ['helper'], rating: 4.2, count: 13, loc: 'Hadapsar');
    user('w23', '9200000023', 'worker', 'Santosh Kamble', 'mr', trades: ['helper'], rating: 4.1, count: 8, loc: 'Aundh');
    user('w24', '9200000024', 'worker', 'Sunita Devi', 'hi', trades: ['helper'], rating: 4.4, count: 18, loc: 'Kharadi');

    // Trust demo data: police-verified shields, a pending + a rejected request (admin queue), and warranty re-fixes owed.
    const police = {'w1': 'verified', 'w3': 'verified', 'w5': 'verified', 'w13': 'verified', 'w16': 'verified', 'w7': 'pending', 'w2': 'pending', 'w10': 'rejected'};
    const refixes = {'w1': 1, 'w3': 2, 'w5': 1, 'w16': 1, 'w13': 1};
    for (final e in police.entries) {
      (users[e.key] as Json)['police'] = e.value;
      if (e.value == 'pending') (users[e.key] as Json)['police_requested_at'] = ago(const Duration(hours: 5));
      if (e.value == 'rejected') (users[e.key] as Json)['police_note'] = 'Address could not be matched';
    }
    for (final e in refixes.entries) {
      (users[e.key] as Json)['refixes'] = e.value;
    }

    Json item(String id, String trade, Map<String, String> text, String lang,
            {bool withAudio = false, int photos = 2, String? transcript, int secs = 24, String? scene, int? wage, int headcount = 1, int days = 1}) =>
        {
          if (wage != null) ...{'headcount': headcount, 'days': days, 'wage': wage},
          'id': id, 'trade': trade, 'lang': lang, 'text': text, 'photos': (demoPhotos[scene ?? trade] ?? demoPhotos['helper']!).take(photos).toList(),
          'transcript': withAudio ? {'hi': transcript ?? text['hi'] ?? text.values.first, 'en': text['en'] ?? text.values.first} : null,
          'audio': withAudio ? {'url': audio, 'duration_sec': secs, 'size_kb': 18} : null,
        };
    final jobs = <String, dynamic>{};
    void job(String id, String cust, String loc, String status, Duration age, List<Json> items,
        {String? address, String kind = 'single', int? schedDay, int schedHour = 9, int schedMin = 0, String slot = 'exact'}) {
      final u = users['c1'] as Json;
      const ll = {'Kothrud': [18.5074, 73.8077], 'Baner': [18.559, 73.7868], 'Hadapsar': [18.5089, 73.926], 'Wakad': [18.5986, 73.7604], 'Aundh': [18.558, 73.8075]};
      jobs[id] = {'id': id, 'city': 'Pune', 'customer_id': cust, 'lat': ll[loc]![0] + 0.002, 'lng': ll[loc]![1] - 0.001, 'address': address ?? 'Flat 302, Sai Residency, $loc, Pune',
        'locality': loc, 'start_date': now.add(const Duration(days: 2)).toIso8601String().substring(0, 10), 'status': status, 'created_at': ago(age),
        'sim_customer': true, 'owner_lang': u['lang'], 'kind': kind,
        'scheduled_for': schedDay == null ? null : DateTime(now.year, now.month, now.day + schedDay, schedHour, schedMin).toUtc().toIso8601String(),
        'time_slot': schedDay == null ? null : slot};
      jobs[id]['items'] = items;
    }

    job('j1', 'c1', 'Kothrud', 'open', const Duration(minutes: 40), [
      item('j1w1', 'plumber', {'hi': 'बाथरूम का नल टपक रहा है, पाइप बदलना है।', 'en': 'Bathroom tap is leaking, the pipe needs replacing.'}, 'hi', withAudio: true, scene: 'tap_leak'),
      item('j1w2', 'mason', {'hi': 'दीवार में सीलन, प्लास्टर ठीक करना है।', 'en': 'Damp wall, plaster needs repair.'}, 'hi', scene: 'damp_wall', photos: 3),
    ], schedDay: 1, schedHour: 9, schedMin: 30);
    job('j2', 'c3', 'Baner', 'bidding', const Duration(hours: 5), [
      item('j2w1', 'electrician', {'en': 'Rewire the kitchen, add 4 new 16A sockets and a chimney point.', 'hi': 'किचन की वायरिंग बदलनी है, 4 नए 16A सॉकेट और चिमनी पॉइंट।'}, 'en', withAudio: true, secs: 37, photos: 3),
      item('j2w2', 'painter', {'en': 'Paint the kitchen after wiring — primer + 2 coats.', 'hi': 'वायरिंग के बाद किचन की पुताई — प्राइमर + 2 कोट।'}, 'en'),
      item('j2w3', 'helper', {'en': 'Move appliances out and clean up debris.', 'hi': 'सामान बाहर निकालना और मलबा साफ़ करना।'}, 'en', photos: 1),
    ], schedDay: 2, schedHour: 8, slot: 'morning');
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
    ], schedDay: 3, schedHour: 16, slot: 'evening');
    // Open jobs so the carpenter and helper feeds are never empty.
    job('j7', 'c3', 'Wakad', 'open', const Duration(hours: 30), [
      item('j7w1', 'carpenter', {'en': 'Need a new sliding wardrobe door fitted in the bedroom and the two kitchen drawer channels replaced.',
        'hi': 'बेडरूम में नया स्लाइडिंग अलमारी दरवाज़ा लगाना है और किचन की दो दराज़ों के चैनल बदलने हैं।'}, 'en'),
    ], schedDay: 1, schedHour: 12, slot: 'afternoon');
    job('j8', 'c1', 'Baner', 'open', const Duration(hours: 52), [
      item('j8w1', 'helper', {'en': 'Two helpers needed for one day to shift furniture and clear old tiles and debris from the flat.',
        'hi': 'एक दिन के लिए दो हेल्पर चाहिए — फ़र्नीचर शिफ़्ट करना और पुरानी टाइलें व मलबा हटाना है।'}, 'en', photos: 2),
    ], schedDay: 2, schedHour: 16, slot: 'evening');
    // Priya's finished plumber job with Imran (3 days ago, paid, rated): inside the 30-day warranty -> "Problem came back" + "Hire again".
    job('jw', 'c1', 'Kothrud', 'completed', const Duration(days: 5), [
      item('jww1', 'plumber', {'en': 'Kitchen sink tap leaking and the waste pipe under the sink drips. Replace the tap and fix the pipe joint.',
        'hi': 'किचन सिंक का नल टपक रहा है और नीचे का वेस्ट पाइप भी रिस रहा है। नल बदलना है और पाइप का जोड़ ठीक करना है।'}, 'en', scene: 'plumber', photos: 1),
    ]);
    // "Hire again": Priya asks Ramesh again - exclusive to him for the next 100 minutes (then it opens to everyone).
    job('jd', 'c1', 'Kothrud', 'open', const Duration(minutes: 20), [
      item('jdw1', 'mason', {'en': 'Balcony wall plaster is cracking and needs patching and finishing, about 80 sq ft. Same as last time.',
        'hi': 'बालकनी की दीवार का प्लास्टर फट रहा है, लगभग 80 वर्ग फ़ुट की मरम्मत और फिनिशिंग चाहिए। पिछली बार जैसा।'}, 'en', withAudio: true, secs: 21, scene: 'damp_wall'),
    ], schedDay: 2, schedHour: 10);
    (jobs['jd'] as Json)
      ..['sim_customer'] = false // Priya answers herself
      ..['direct_worker'] = 'w1'
      ..['direct_declined'] = false
      ..['direct_until'] = now.add(const Duration(minutes: 100)).toIso8601String();
    // Contractor team sites (Anil Deshmukh): one running, one collecting applications.
    job('t1', 'c2', 'Hadapsar', 'in_progress', const Duration(days: 4), [
      item('t1w1', 'mason', {'en': 'Boundary wall and plaster for a new plot, 3 masons for 5 days. Bring your own tools; lunch provided.',
        'hi': 'नए प्लॉट पर बाउंड्री वॉल और प्लास्टर, 3 राजमिस्त्री 5 दिन के लिए। अपने औज़ार लाएँ; खाना मिलेगा।'}, 'en', wage: 950, headcount: 3, days: 5),
      item('t1w2', 'helper', {'en': 'Three helpers to carry bricks, mix cement and clean the site for 5 days at the same plot.',
        'hi': 'उसी प्लॉट पर 5 दिन ईंट ढोने, सीमेंट मिलाने और सफ़ाई के लिए 3 हेल्पर।'}, 'en', wage: 800, headcount: 3, days: 5),
    ], kind: 'team', schedDay: -2, schedHour: 8, slot: 'morning', address: 'Plot 14, Hadapsar, Pune');
    job('t2', 'c2', 'Baner', 'bidding', const Duration(days: 1), [
      item('t2w1', 'painter', {'en': 'Two painters for putty, primer and two coats on a 3 BHK flat, 4 days. Material is on site.',
        'hi': '3 BHK फ़्लैट पर पुट्टी, प्राइमर और दो कोट के लिए 2 पेंटर, 4 दिन। सामान साइट पर है।'}, 'en', wage: 900, headcount: 2, days: 4),
      item('t2w2', 'carpenter', {'en': 'Two carpenters for modular wardrobes and door frames in a new flat, 3 days.',
        'hi': 'नए फ़्लैट में मॉड्यूलर अलमारी और दरवाज़े के फ़्रेम के लिए 2 बढ़ई, 3 दिन।'}, 'en', wage: 1300, headcount: 2, days: 3),
    ], kind: 'team', schedDay: 2, schedHour: 8, slot: 'morning', address: 'Flat 8, Baner, Pune');

    final bids = <String, dynamic>{};
    // Seed quotes come from the pricing model (what that worker's trades would fairly charge), x factor.
    int quote(String job, String w, double f) {
      final jj = jobs[job] as Map;
      final pairs = <(String, String?)>[
        for (final it in (jj['items'] as List).cast<Map>())
          (it['trade'] as String, (it['text'] as Map)['en'] as String? ?? (it['text'] as Map).values.first as String?)
      ];
      final median = DemoPricing.fairRange(pairs, 'Pune', (users[w] as Map)['trades'] as List)['median'] as num;
      return (median * f / 50).round() * 50;
    }

    void bid(String id, String job, String w, double f, String status, Duration age) =>
        bids[id] = {'id': id, 'job_id': job, 'worker_id': w, 'price': quote(job, w, f), 'status': status, 'created_at': ago(age)};
    bid('b1', 'j2', 'w5', 0.95, 'pending', const Duration(hours: 4));
    bid('b2', 'j2', 'w6', 0.35, 'pending', const Duration(hours: 3)); // deliberately below minimum wage (Fair Wage Shield demo)
    bid('b3', 'j2', 'w9', 1.05, 'pending', const Duration(hours: 2));
    bid('b4', 'j3', 'w7', 1.0, 'accepted', const Duration(days: 3));
    bid('b5', 'j3', 'w8', 1.1, 'rejected', const Duration(days: 3));
    bid('b6', 'j4', 'w1', 1.0, 'accepted', const Duration(days: 6));
    bid('b7', 'j5', 'w9', 1.0, 'accepted', const Duration(days: 8));
    bid('b8', 'j6', 'w3', 1.05, 'pending', const Duration(hours: 18));
    bid('b9', 'j6', 'w4', 0.92, 'pending', const Duration(hours: 10));
    bids['bw'] = {'id': 'bw', 'job_id': 'jw', 'worker_id': 'w3', 'price': 1300, 'status': 'accepted', 'created_at': ago(const Duration(days: 5))};
    int pr(String id) => (bids[id] as Map)['price'] as int;
    // team applications / hires (price = DAILY wage)
    void tbid(String id, String jobId, String itemId, String w, int wage, String status) =>
        bids[id] = {'id': id, 'job_id': jobId, 'worker_id': w, 'item_id': itemId, 'price': wage, 'status': status, 'created_at': ago(const Duration(days: 3))};
    tbid('tb1', 't1', 't1w1', 'w1', 950, 'accepted');
    tbid('tb2', 't1', 't1w1', 'w11', 950, 'accepted');
    tbid('tb3', 't1', 't1w2', 'w21', 800, 'accepted');
    tbid('tb4', 't1', 't1w1', 'w2', 1000, 'pending');
    tbid('tb5', 't1', 't1w2', 'w22', 800, 'pending');
    tbid('tb6', 't2', 't2w1', 'w9', 900, 'pending');
    tbid('tb7', 't2', 't2w1', 'w19', 950, 'pending');
    tbid('tb8', 't2', 't2w2', 'w7', 1300, 'pending');

    final assignments = <String, dynamic>{
      'a3': {'id': 'a3', 'job_id': 'j3', 'worker_id': 'w7', 'bid_id': 'b4', 'nonce': 'seed3'}, // Priya sees the start code for him
      'a4': {'id': 'a4', 'job_id': 'j4', 'worker_id': 'w1', 'bid_id': 'b6', 'started_at': ago(const Duration(days: 2)),
        'journey_started_at': ago(const Duration(days: 2, minutes: 30)), 'nonce': 'seed4'},
      'aw': {'id': 'aw', 'job_id': 'jw', 'worker_id': 'w3', 'bid_id': 'bw', 'started_at': ago(const Duration(days: 3, hours: 4)),
        'completed_at': ago(const Duration(days: 3)), 'nonce': 'seedw'},
      'a5': {'id': 'a5', 'job_id': 'j5', 'worker_id': 'w9', 'bid_id': 'b7', 'started_at': ago(const Duration(days: 8)), 'completed_at': ago(const Duration(days: 1)),
        'no_auto': true, 'nonce': 'seed5'}, // seeded "awaiting rating" example stays that way (real jobs follow the 48 h rule)
    };
    final payments = <String, dynamic>{
      'p3': {'id': 'p3', 'assignment_id': 'a3', 'amount': pr('b4') + fee, 'fee': fee, 'payout': pr('b4'), 'state': 'held', 'method': 'upi', 'paid_at': ago(const Duration(days: 3))},
      'p4': {'id': 'p4', 'assignment_id': 'a4', 'amount': pr('b6') + fee, 'fee': fee, 'payout': pr('b6'), 'state': 'held', 'method': 'upi', 'paid_at': ago(const Duration(days: 6))},
      'pw': {'id': 'pw', 'assignment_id': 'aw', 'amount': 1300 + fee, 'fee': fee, 'payout': 1300, 'state': 'released', 'method': 'upi',
        'paid_at': ago(const Duration(days: 4)), 'released_at': ago(const Duration(days: 3, hours: -2))},
      'p5': {'id': 'p5', 'assignment_id': 'a5', 'amount': pr('b7') + fee, 'fee': fee, 'payout': pr('b7'), 'state': 'held', 'method': 'card', 'paid_at': ago(const Duration(days: 8))}, // awaiting rating
    };
    // Hired team members: own assignment + escrow (wage x 5 days + fee), checked in on site.
    final teamAtt = <Json>[];
    for (final (i, row) in [('ta1', 'w1', 'tb1', 't1w1', 950), ('ta2', 'w11', 'tb2', 't1w1', 950), ('ta3', 'w21', 'tb3', 't1w2', 800)].indexed) {
      final (aid, w, b, itemId, wage) = row;
      assignments[aid] = {'id': aid, 'job_id': 't1', 'worker_id': w, 'bid_id': b, 'item_id': itemId, 'days': 5, 'started_at': ago(const Duration(days: 2)),
        'journey_started_at': ago(const Duration(days: 2, minutes: 30)), 'nonce': 'seed$aid'};
      payments['tp${i + 1}'] = {'id': 'tp${i + 1}', 'assignment_id': aid, 'amount': wage * 5 + fee, 'fee': fee, 'payout': wage * 5, 'state': 'held',
        'method': 'upi', 'paid_at': ago(const Duration(days: 3))};
      for (final back in i == 2 ? [2, 1] : [2, 1, 0]) {
        var t = DateTime(now.year, now.month, now.day - back, 9, 5 + i * 6);
        if (t.isAfter(now)) t = now.subtract(Duration(minutes: 8 + i));
        teamAtt.add({'assignment_id': aid, 'in': t.toIso8601String(), 'out': back == 0 ? null : t.add(const Duration(hours: 8, minutes: 15)).toIso8601String(),
          'offline': i == 1 && back == 1, 'geofence_ok': true});
      }
    }
    final ratings = <Json>[
      {'assignment_id': 'aw', 'direction': 'customer_to_worker', 'ratee': 'w3', 'quality': 5, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 4,
        'overall': 4.75, 'comment': 'Fixed it neatly', 'created_at': ago(const Duration(days: 3, hours: -2))},
    ];
    // History: past rated + paid jobs for experienced workers (profile, breakdown, earnings).
    const comments = ['Very neat work', 'Came on time', 'Good behaviour, fair price', 'Bahut accha kaam', null];
    var h = 0;
    for (final w in users.values.cast<Json>().where((u) => u['role'] == 'worker' && (u['rating_count'] as int) > 0)) {
      final streaky = w['id'] == 'w1'; // Ramesh: a job in each of the last 4 weeks -> "4-week streak"
      for (var k = 0; k < (streaky ? 4 : 3); k++, h++) {
        final jid = 'hj$h', aid = 'ha$h', bid0 = 'hb$h', pid = 'hp$h';
        final trade = (w['trades'] as List).first as String;
        final when = streaky ? now.subtract(Duration(hours: 4, days: k * 7)) : now.subtract(Duration(days: 14 + k * 10));
        final samples = DemoPricing.sampleJobs[trade]!;
        final sample = samples[(h + k) % samples.length];
        jobs[jid] = {'id': jid, 'city': 'Pune', 'customer_id': ['c1', 'c2', 'c3'][k % 3], 'lat': w['lat'], 'lng': w['lng'], 'address': 'Pune', 'locality': ['Kothrud', 'Baner', 'Aundh'][k % 3],
          'start_date': when.toIso8601String().substring(0, 10), 'status': 'completed', 'created_at': when.subtract(const Duration(days: 3)).toIso8601String(),
          'items': [
            {...item('${jid}w', trade, {'en': sample, 'hi': 'काम'}, 'en', photos: 1),
              'photos': [demoPhotos[trade]![k % demoPhotos[trade]!.length]]}
          ]};
        final price = ((DemoPricing.estimateItem(trade, sample, 'Pune')['median_inr'] as int) * (0.88 + _rnd.nextDouble() * 0.24) / 50).round() * 50;
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
      'city': 'Pune', 'users': users, 'jobs': jobs, 'bids': bids, 'assignments': assignments, 'payments': payments, 'ratings': ratings,
      'payouts': [
        {'worker_id': 'w1', 'amount': 2400, 'upi': 'ra****@okaxis', 'at': ago(const Duration(days: 12)), 'source': 'withdraw', 'state': 'paid'},
        // same-day pay: Imran's payout from the warranty job went to UPI the moment it was released ("Paid today")
        {'id': 'po1', 'worker_id': 'w3', 'amount': 1300, 'upi': 'im****@okaxis', 'at': ago(const Duration(hours: 1)), 'paid_at': ago(const Duration(minutes: 59)),
          'source': 'auto', 'state': 'paid', 'assignment_id': 'aw', 'notified': true},
      ],
      'attendance': [
        ...teamAtt,
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

/// Skill ladder (Helper -> Semi-skilled -> Skilled -> Master) and weekly streak. Mirror of backend/app/domain/levels.py +
/// `skill_levels` in config.py - keep both in sync.
class DemoLevels {
  static const rules = <Map<String, Object?>>[
    {'code': 'helper', 'min_jobs': 0, 'min_rating': 0.0, 'max_refix_rate': null, 'fair_multiplier': 1.0},
    {'code': 'semi_skilled', 'min_jobs': 5, 'min_rating': 4.0, 'max_refix_rate': null, 'fair_multiplier': 1.0},
    {'code': 'skilled', 'min_jobs': 20, 'min_rating': 4.3, 'max_refix_rate': null, 'fair_multiplier': 1.1},
    {'code': 'master', 'min_jobs': 60, 'min_rating': 4.6, 'max_refix_rate': 0.05, 'fair_multiplier': 1.25},
  ];

  static double refixRate(int jobs, int refixes) => jobs > 0 ? double.parse((refixes / jobs).toStringAsFixed(4)) : 0.0;

  static bool _meets(Map<String, Object?> r, int jobs, double rating, double rate) {
    if (jobs < (r['min_jobs'] as int) || rating < (r['min_rating'] as num)) return false;
    final cap = r['max_refix_rate'] as num?;
    return cap == null || rate < cap;
  }

  /// Highest level whose rules ALL hold, walking up from Helper (a gap stops the climb).
  static Map<String, dynamic> levelFor(int jobs, double rating, int refixes) {
    final rate = refixRate(jobs, refixes);
    var cur = rules.first;
    for (final r in rules.skip(1)) {
      if (_meets(r, jobs, rating, rate)) {
        cur = r;
      } else {
        break;
      }
    }
    return {...cur.cast<String, dynamic>()};
  }

  /// Level card: current + next level, what is still missing, progress 0..1.
  static Map<String, dynamic> view(int jobs, double rating, int refixes) {
    final rate = refixRate(jobs, refixes);
    final cur = levelFor(jobs, rating, refixes);
    final idx = rules.indexWhere((r) => r['code'] == cur['code']);
    final nxt = idx + 1 < rules.length ? rules[idx + 1] : null;
    final out = <String, dynamic>{'code': cur['code'], 'index': idx, 'jobs': jobs, 'rating': double.parse(rating.toStringAsFixed(1)), 'refix_rate': rate,
      'refixes': refixes, 'fair_multiplier': cur['fair_multiplier'], 'next': null, 'needs': <Map<String, dynamic>>[], 'progress': 1.0};
    if (nxt != null) {
      final needs = <Map<String, dynamic>>[];
      final minJobs = nxt['min_jobs'] as int, minRating = (nxt['min_rating'] as num).toDouble();
      if (jobs < minJobs) needs.add({'kind': 'jobs', 'need': minJobs - jobs});
      if (rating < minRating) needs.add({'kind': 'rating', 'need': minRating});
      final cap = nxt['max_refix_rate'] as num?;
      if (cap != null && rate >= cap) needs.add({'kind': 'refix_rate', 'need': (cap * 100).round()});
      final parts = [minJobs > 0 ? min(1.0, jobs / minJobs) : 1.0, minRating > 0 ? min(1.0, rating / minRating) : 1.0];
      out['next'] = {'code': nxt['code'], 'min_jobs': minJobs, 'min_rating': minRating, 'max_refix_rate_pct': cap == null ? null : (cap * 100).round()};
      out['needs'] = needs;
      out['progress'] = double.parse(parts.reduce(min).toStringAsFixed(3));
    }
    return out;
  }

  /// ISO week as year*100+week (weeks start on Monday).
  static int weekKey(DateTime d) {
    final day = DateTime.utc(d.year, d.month, d.day);
    final thursday = day.add(Duration(days: 4 - day.weekday));
    final jan1 = DateTime.utc(thursday.year, 1, 1);
    return thursday.year * 100 + (thursday.difference(jan1).inDays ~/ 7) + 1;
  }

  /// Consecutive weeks with a completed job. The current week may still be empty without breaking the streak.
  static Map<String, dynamic> streakFromWeeks(Set<int> weeks, DateTime today) {
    final alive = weeks.contains(weekKey(today));
    var cursor = DateTime.utc(today.year, today.month, today.day);
    if (!alive) cursor = cursor.subtract(const Duration(days: 7));
    var n = 0;
    while (weeks.contains(weekKey(cursor))) {
      n++;
      cursor = cursor.subtract(const Duration(days: 7));
    }
    return {'weeks': n, 'alive_this_week': alive};
  }
}

/// Mirror of backend/app/domain/pricing.py — keep both in sync (same rates, parsing and rounding).
/// Tier-1 labour-only rupees from the 2025-26 analyst notes, times a city-tier multiplier.
class DemoPricing {
  static const _tier1 = {'mumbai', 'delhi', 'new delhi', 'bengaluru', 'bangalore', 'pune', 'hyderabad', 'chennai', 'kolkata', 'ahmedabad'};
  static const _tier2 = {'jaipur', 'lucknow', 'chandigarh', 'ludhiana', 'jalandhar', 'amritsar', 'indore', 'nagpur', 'surat', 'kochi',
    'bhopal', 'coimbatore', 'vadodara', 'patna', 'kanpur', 'nashik', 'visakhapatnam', 'thane', 'noida', 'gurugram', 'gurgaon',
    'ghaziabad', 'faridabad', 'mohali', 'dehradun', 'ranchi', 'raipur', 'bhubaneswar', 'guwahati', 'thiruvananthapuram', 'madurai',
    'mysuru', 'mysore', 'rajkot', 'agra', 'varanasi', 'meerut', 'patiala'};

  static double cityMultiplier(String? city) {
    final c = (city ?? '').trim().toLowerCase();
    if (_tier1.contains(c)) return 1.0;
    if (_tier2.contains(c)) return 0.85;
    return 0.8;
  }

  /// Rough city centres so a phone with no working geocoder still gets the right price tier.
  static const _centres = <String, List<double>>{
    'Mumbai': [19.076, 72.8777], 'Delhi': [28.6139, 77.209], 'Bengaluru': [12.9716, 77.5946], 'Pune': [18.5204, 73.8567],
    'Hyderabad': [17.385, 78.4867], 'Chennai': [13.0827, 80.2707], 'Kolkata': [22.5726, 88.3639], 'Ahmedabad': [23.0225, 72.5714],
    'Jaipur': [26.9124, 75.7873], 'Lucknow': [26.8467, 80.9462], 'Chandigarh': [30.7333, 76.7794], 'Ludhiana': [30.901, 75.8573],
    'Jalandhar': [31.326, 75.5762], 'Amritsar': [31.634, 74.8723], 'Indore': [22.7196, 75.8577], 'Nagpur': [21.1458, 79.0882],
    'Surat': [21.1702, 72.8311], 'Kochi': [9.9312, 76.2673], 'Bhopal': [23.2599, 77.4126], 'Coimbatore': [11.0168, 76.9558],
    'Vadodara': [22.3072, 73.1812], 'Patna': [25.5941, 85.1376], 'Kanpur': [26.4499, 80.3319], 'Nashik': [19.9975, 73.7898],
    'Visakhapatnam': [17.6868, 83.2185], 'Dehradun': [30.3165, 78.0322], 'Ranchi': [23.3441, 85.3096], 'Raipur': [21.2514, 81.6296],
    'Bhubaneswar': [20.2961, 85.8245], 'Guwahati': [26.1445, 91.7362], 'Thiruvananthapuram': [8.5241, 76.9366], 'Agra': [27.1767, 78.0081],
    'Varanasi': [25.3176, 82.9739],
  };

  /// Nearest known city within 60 km, else null.
  static String? cityNear(double lat, double lng) {
    String? best;
    var bestKm = 60.0;
    _centres.forEach((name, c) {
      final dLat = (c[0] - lat) * pi / 180, dLng = (c[1] - lng) * pi / 180;
      final h = pow(sin(dLat / 2), 2) + cos(lat * pi / 180) * cos(c[0] * pi / 180) * pow(sin(dLng / 2), 2);
      final km = 2 * 6371 * asin(sqrt(h));
      if (km < bestKm) {
        bestKm = km;
        best = name;
      }
    });
    return best;
  }

  // PLACEHOLDER minimum wages (approx. central-sphere construction, per 8-hour day).
  // Must be verified against the current Chief Labour Commissioner / state notification before launch.
  static const minWage = {'unskilled': 783, 'semi_skilled': 868, 'skilled': 954};
  static const tradeSkill = {'helper': 'unskilled', 'painter': 'semi_skilled', 'mason': 'skilled', 'carpenter': 'skilled',
    'plumber': 'skilled', 'electrician': 'skilled'};
  static int minWagePerDay(String trade) => minWage[tradeSkill[trade] ?? 'skilled']!;

  static const _dayRate = <String, List<num>>{'mason': [650, 850, 1000], 'carpenter': [900, 1300, 1800], 'plumber': [650, 800, 1000],
    'electrician': [700, 900, 1200], 'painter': [700, 900, 1100], 'helper': [500, 600, 700]};
  static const _wallSqft = <num>[60, 75, 90];
  static const _tilingSqft = <num>[45, 60, 80];
  static const _plasterSqft = <num>[25, 32, 40];
  static const _paintSqft = <num>[8, 10, 12];
  static const _plumbPoint = <num>[280, 360, 450];
  static const _plumbSmall = <num>[400, 550, 700];
  static const _plumbVisit = <num>[250, 320, 400];
  static const _elecSocket = <num>[250, 320, 400];
  static const _elecNew = <num>[800, 1050, 1300];
  static const _elecRewire = <num>[375, 500, 625];
  static const _elecVisit = <num>[200, 280, 350];

  /// Typical jobs per trade (seed history).
  static const sampleJobs = <String, List<String>>{
    'mason': ['Compound wall 40 ft, 5 ft height', 'Plaster damaged wall, 1 day', 'Bathroom floor tiling 60 sq ft', 'Brick wall repair 2 days'],
    'plumber': ['Bathroom tap leak', 'Fix leaking pipe', 'Install 3 plumbing points', 'Replace kitchen tap'],
    'electrician': ['Rewire kitchen, 4 points', 'Install 3 sockets', 'Fix switchboard', 'Add 2 new points'],
    'carpenter': ['Fix wardrobe door hinge', 'Repair 2 drawers', 'Door repair 2 days', 'Modular kitchen repair'],
    'painter': ['Paint kitchen', 'Repaint living room 900 sq ft', 'Paint bedroom 400 sq ft', 'Touch-up door grill'],
    'helper': ['Material shifting 2 days', 'Debris removal', 'Site cleaning 1 day', 'Helper for mason 3 days'],
  };

  static final _sqftRe = RegExp(r'(\d[\d,]*(?:\.\d+)?)\s*(?:sq\.?\s*ft|sqft|square\s*f(?:ee|oo)t|वर्ग\s*फ)', caseSensitive: false);
  static final _ftRe = RegExp(r'(\d[\d,]*(?:\.\d+)?)\s*(?:ft|feet|foot|फुट|फीट)(?![a-z])', caseSensitive: false);
  static final _daysRe = RegExp(r'(\d+(?:\.\d+)?)\s*(?:days?|din|दिन)', caseSensitive: false);
  static final _pointsRe = RegExp(r'(\d+)\s*(?:[\w\-]+\s+){0,2}?(?:sockets?|points?|switch(?:es)?|plugs?|लाइट|पॉइंट|सॉकेट)', caseSensitive: false);

  static double _num(Match m) => double.parse(m.group(1)!.replaceAll(',', ''));
  static int _r50(num x) => (x / 50).round() * 50;
  static int _step(num x) => x >= 500 ? 50 : 10;
  static int _round(num x, int step) => (x / step + 0.5).floor() * step;
  static int _ceil(num x, int step) => (x / step - 1e-9).ceil() * step;

  /// Guarantees low < median < high with a sensible spread (the "₹400 to ₹400" bug): median >= low x 1.12,
  /// high >= low x 1.3 and high > median; rounded to ₹50 (₹10 under ₹500). Mirrors `pricing.spread` in the backend.
  static (int, int, int) spread(num low, num med, num high) {
    final step = _step(low);
    final lo = max(_round(low, step), step);
    var md = max(_round(med, step), _ceil(lo * 1.12, step));
    if (md <= lo) md = lo + step;
    var hi = max(max(_round(high, step), _ceil(lo * 1.3, step)), _ceil(md * 1.1, step));
    if (hi <= md) hi = md + step;
    return (lo, md, hi);
  }

  /// Daily wage suggestion for a contractor's team line. `low` is never below the minimum wage.
  static Map<String, dynamic> dayWageRange(String trade, String? city) {
    final r = _dayRate[trade] ?? _dayRate['helper']!;
    final m = cityMultiplier(city);
    final mw = minWagePerDay(trade);
    final (lo, md, hi) = spread(max(_r50(r[0] * m), (mw / 50).ceil() * 50), r[1] * m, r[2] * m);
    return {'trade': trade, 'low': lo, 'median': md, 'high': hi, 'min_wage': mw};
  }
  static bool _has(String t, List<String> words) {
    final s = t.toLowerCase();
    return words.any(s.contains);
  }

  static List<num> _scale(List<num> r, num q) => [for (final x in r) x * q];

  /// -> [rates(low, median, high), days, basis]
  static (List<num>, double, String) _base(String trade, String text) {
    final daysM = _daysRe.firstMatch(text);
    final days = daysM == null ? null : min(_num(daysM), 60.0);
    final sq = _sqftRe.firstMatch(text);
    final sqft = sq == null ? null : _num(sq);
    final ptsM = _pointsRe.firstMatch(text);
    final pts = ptsM == null ? null : int.parse(ptsM.group(1)!);

    if (trade == 'painter') {
      final area = sqft ?? 750.0;
      return (_scale(_paintSqft, area), max(1.0, (area / 250).ceilToDouble()), '${area.toInt()} sq ft');
    }
    if (trade == 'mason') {
      final ft = _ftRe.firstMatch(text);
      if (ft != null && _has(text, ['wall', 'दीवार']) && days == null) {
        final length = _num(ft);
        return (_scale(_wallSqft, length * 5), max(1.0, (length / 9).ceilToDouble()), '${length.toInt()} ft wall');
      }
      if (sqft != null && _has(text, ['til', 'टाइल'])) {
        return (_scale(_tilingSqft, sqft), max(1.0, (sqft / 60).ceilToDouble()), '${sqft.toInt()} sq ft tiling');
      }
      if (sqft != null) {
        return (_scale(_plasterSqft, sqft), max(1.0, (sqft / 120).ceilToDouble()), '${sqft.toInt()} sq ft plaster');
      }
      final d = days ?? 1.0;
      return (_scale(_dayRate['mason']!, d), d, '$d day');
    }
    if (trade == 'electrician') {
      if (pts != null) {
        final rate = _has(text, ['rewir', 'वायरिंग']) ? _elecRewire : (_has(text, ['new point', 'नया पॉइंट']) ? _elecNew : _elecSocket);
        return (_scale(rate, pts), max(0.5, pts * 0.25), '$pts points');
      }
      if (days != null) return (_scale(_dayRate['electrician']!, days), days, '$days day');
      return (_elecVisit, 0.4, '1 visit');
    }
    if (trade == 'plumber') {
      if (pts != null && !_has(text, ['leak', 'tap'])) return (_scale(_plumbPoint, pts), max(0.5, pts * 0.25), '$pts points');
      if (_has(text, ['pipeline', 'पाइपलाइन', 'full flat', 'repip'])) {
        final d = days ?? 3.0;
        return (_scale(_dayRate['plumber']!, d), d, '$d day');
      }
      if (_has(text, ['tap', 'leak', 'टपक', 'नल', 'लीक', 'drip', 'seep'])) return (_plumbSmall, 0.4, 'small fix');
      if (days != null) return (_scale(_dayRate['plumber']!, days), days, '$days day');
      return (_plumbVisit, 0.4, '1 visit');
    }
    final d = days ?? 1.0; // carpenter, helper, anything else
    return (_scale(_dayRate[trade] ?? _dayRate['helper']!, d), d, '$d day');
  }

  /// One work item. Low is floored at the minimum wage for the estimated days.
  static Map<String, dynamic> estimateItem(String trade, String? text, String? city) {
    final (rates, days, basis) = _base(trade, text ?? '');
    final m = cityMultiplier(city);
    final mw = minWagePerDay(trade) * days;
    final step = _step(max(rates[0] * m, mw));
    final lo0 = max(_round(rates[0] * m, step), _ceil(mw, step)); // never below the legal wage for the estimated days
    final (lo, med, hi) = spread(lo0, rates[1] * m, rates[2] * m);
    return {'trade': trade, 'low_inr': lo, 'median_inr': med, 'high_inr': hi, 'est_days': double.parse(days.toStringAsFixed(1)),
      'min_wage_total': mw.round(), 'basis': basis};
  }

  /// [items] = (trade, text) pairs. Returns the same shape as the backend `/customer/price-estimate`.
  static Map<String, dynamic> estimateItems(List<(String, String?)> items, String? city) {
    final out = [for (final i in items) estimateItem(i.$1, i.$2, city)];
    int sum(String k) => out.fold<int>(0, (s, i) => s + (i[k] as int));
    return {'items': out, 'total_low_inr': sum('low_inr'), 'total_median_inr': sum('median_inr'), 'total_high_inr': sum('high_inr')};
  }

  /// Skill-ladder band (mirror of backend `scale_range`): a higher level may ask more. Scales low/median/high but NEVER the
  /// legal minimum: `low` stays >= min_wage_total and low < median < high holds.
  static Map<String, dynamic> scaleRange(Map<String, dynamic> fr, double mult) {
    if (mult == 1.0) return fr;
    final mw = fr['min_wage_total'] as num;
    final lo = (fr['low'] as num) * mult, md = (fr['median'] as num) * mult, hi = (fr['high'] as num) * mult;
    final step = _step(max(lo, mw));
    final lo2 = max(_round(lo, step), _ceil(mw, step));
    final (a, b, c) = spread(lo2, md, hi);
    return {...fr, 'low': a, 'median': b, 'high': c};
  }

  /// Fair range for a job; [trades] limits it to one worker's trades (falls back to the whole job); [mult] = skill-ladder multiplier.
  static Map<String, dynamic> fairRange(List<(String, String?)> items, String? city, [List? trades, double mult = 1.0]) {
    var use = items;
    if (trades != null && trades.isNotEmpty) {
      final sub = items.where((i) => trades.contains(i.$1)).toList();
      if (sub.isNotEmpty) use = sub;
    }
    final est = estimateItems(use, city);
    final its = est['items'] as List;
    final days = its.fold<double>(0, (s, i) => s + ((i as Map)['est_days'] as num).toDouble());
    final mw = its.fold<int>(0, (s, i) => s + ((i as Map)['min_wage_total'] as int));
    // Where the market rate sits near the wage floor, keep a real spread above it.
    final (low, median, high) = spread(est['total_low_inr'] as num, est['total_median_inr'] as num, est['total_high_inr'] as num);
    return scaleRange({'low': low, 'median': median, 'high': high,
      'min_wage_total': mw, 'est_days': double.parse(days.toStringAsFixed(1))}, mult);
  }

  /// Never blocks: fair | below_min_wage | high.
  static Map<String, dynamic> fairCheck(num price, List<(String, String?)> items, String? city, [List? trades, double mult = 1.0]) {
    final r = fairRange(items, city, trades, mult);
    final verdict = price < (r['min_wage_total'] as num) ? 'below_min_wage' : (price > (r['high'] as num) * 1.2 ? 'high' : 'fair');
    return {'verdict': verdict, 'low': r['low'], 'high': r['high'], 'min_wage_total': r['min_wage_total']};
  }
}
