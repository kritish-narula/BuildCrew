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
