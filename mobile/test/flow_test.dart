import 'package:buildcrew/core/api.dart';
import 'package:buildcrew/core/demo_accounts.dart';
import 'package:buildcrew/core/demo_api.dart';
import 'package:buildcrew/core/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end marketplace flow against the on-device demo backend (no widgets).
/// DemoApi represents "who is signed in" with a single `_me`, so ONE instance is used and the
/// persona is switched by verifying the demo OTP for another phone number (same as the app's
/// "switch account" helper). Two DemoApi instances would each cache their own copy of the db.
const _priya = '9100000001'; // customer c1
const _neha = '9100000003'; // customer c3 (owns seeded job j2 with 3 quotes)
const _ramesh = '9200000001'; // mason w1
const _sunil = '9200000002'; // mason + helper w2

const _instruction = 'Compound wall 40 ft, 5 ft high, 9-inch brick';
const _photo = 'photos/wall_site_1.jpg';
const _photo2 = 'photos/wall_site_2.jpg';
// The post-job rules need >= 50 characters and >= 2 photos; keep the wall keywords for pricing.
const _longInstruction = 'Compound wall 40 ft, 5 ft high, 9-inch brick, plaster not needed';

String _inDays(int n) => DateTime.now().add(Duration(days: n)).toIso8601String().substring(0, 10);

late DemoApi api;

Future<SessionUser> signInAs(String phone) async {
  final r = await api.verifyOtp(phone, '123456', role: phone.startsWith('91') ? 'customer' : 'worker', lang: 'en');
  return r.user;
}

String _daysAhead(int n) {
  final d = DateTime.now().add(Duration(days: n));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Json _jobBody() => {
      'location_lat': 18.5074,
      'location_lng': 73.8077,
      'address_text': 'Plot 12, Kothrud, Pune',
      'city': 'Pune',
      'locality': 'Kothrud',
      'start_date': _daysAhead(3),
      'work_items': [
        {
          'trade': 'mason',
          'description_language': 'en',
          'text_description': _longInstruction,
          'photo_keys': [_photo, _photo2],
          'transcript': null,
          'audio_key': null,
        }
      ],
    };

/// The customer reads today's start code; the worker enters it (the demo's equivalent of the check-in sheet).
/// Leaves the worker signed in. No-op when no code is needed any more.
Future<void> startWithCode(String worker, String jobId, String aid, {String customer = _priya}) async {
  await signInAs(customer);
  final a = (await api.customerJob(jobId))['assignment'] as Map;
  final code = (a['start_code'] as Map?)?['code'] as String?;
  await signInAs(worker);
  if (code != null) await api.startWork(aid, code: code);
}

String _wrongCode(String code) => code == '0000' ? '1111' : '0000';

Matcher _apiError(String code) => throwsA(isA<ApiException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = DemoApi()..language = 'en';
  });

  group('auth', () {
    test('demo OTP: 123456 signs in, anything else is rejected', () async {
      await expectLater(api.verifyOtp(_priya, '000000', role: 'customer', lang: 'en'), _apiError('err.otp_invalid'));
      final u = await signInAs(_priya);
      expect(u.role, 'customer');
      expect(u.name, 'Priya Sharma');
      final w = await signInAs(_ramesh);
      expect(w.role, 'worker');
      expect(w.name, 'Ramesh Pawar');
    });
  });

  group('pricing', () {
    test('40 ft compound wall in a tier-1 city is about 12-18k', () async {
      final est = await api.priceEstimate(['mason'], 'Kothrud', texts: ['Compound wall 40 ft, 5 ft high'], city: 'Pune');
      final median = est['total_median_inr'] as int;
      expect(median, inInclusiveRange(12000, 18000));
      expect(est['total_low_inr'] as int, lessThanOrEqualTo(median));
      expect(est['total_high_inr'] as int, greaterThanOrEqualTo(median));
      expect(est['total_high_inr'] as int, lessThanOrEqualTo(22000));
      expect(est['platform_fee_inr'], 30);
      final item = (est['items'] as List).first as Map;
      expect(item['trade'], 'mason');
      // The low end can never be under the legal minimum wage for the estimated days.
      expect(item['low_inr'] as int, greaterThanOrEqualTo(item['min_wage_total'] as int));
    });

    test('tier-2 city is cheaper than tier-1 for the same wall', () async {
      final pune = await api.priceEstimate(['mason'], null, texts: [_instruction], city: 'Pune');
      final jal = await api.priceEstimate(['mason'], null, texts: [_instruction], city: 'Jalandhar');
      expect(jal['total_median_inr'] as int, lessThan(pune['total_median_inr'] as int));
    });

    test('fair check verdicts: below_min_wage / fair / high', () {
      final items = [('mason', _instruction)];
      expect(DemoPricing.fairCheck(3000, items, 'Pune')['verdict'], 'below_min_wage');
      expect(DemoPricing.fairCheck(15000, items, 'Pune')['verdict'], 'fair');
      expect(DemoPricing.fairCheck(40000, items, 'Pune')['verdict'], 'high');
    });

    test('seeded below-minimum-wage quote is flagged for the customer', () async {
      await signInAs(_neha);
      final job = await api.customerJob('j2');
      final bids = (job['bids'] as List).cast<Map>();
      expect(bids.length, 3);
      final verdicts = {for (final b in bids) (b['worker'] as Map)['id']: (b['fair'] as Map)['verdict']};
      expect(verdicts['w6'], 'below_min_wage'); // seed: 0.35 x fair price
      expect(verdicts['w5'], 'fair');
      expect(verdicts['w9'], 'fair');
    });
  });

  group('marketplace flow', () {
    test('post -> quote -> accept -> pay -> journey -> done -> rate -> release -> receipt', () async {
      // ------------------------------------------------ customer posts a job (photo + text)
      final priya = await signInAs(_priya);
      final created = await api.createJob(_jobBody());
      final jobId = created['id'] as String;
      expect(created['status'], 'open');

      final mine = await api.customerJobs();
      final posted = mine.firstWhere((j) => j['id'] == jobId);
      expect(posted['status'], 'open');
      expect(posted['thumbnail'], _photo);
      expect(posted['trades'], ['mason']);

      // ------------------------------------------------ worker sees it in the feed and in detail
      final ramesh = await signInAs(_ramesh);
      final feed = await api.workerFeed();
      final card = feed.firstWhere((j) => j['id'] == jobId, orElse: () => <String, dynamic>{});
      expect(card, isNotEmpty, reason: 'new mason job must appear in the mason worker feed');
      expect(card['thumbnails'], contains(_photo));
      expect(card['work_count'], 1);
      expect((card['trades'] as List).first, {'code': 'mason'});
      expect(card['already_bid'], false);

      final detail = await api.workerJob(jobId);
      final item = (detail['work_items'] as List).first as Map;
      expect(item['photos'], [_photo, _photo2]);
      expect(item['text'], _longInstruction);
      expect(item['trade'], 'mason');
      final fr = detail['fair_range'] as Map;
      expect(fr['median'] as int, inInclusiveRange(12000, 18000));
      expect(fr['low'] as int, lessThan(fr['median'] as int));
      expect(fr['high'] as int, greaterThan(fr['median'] as int));
      expect(fr['min_wage_total'] as int, greaterThan(0));
      expect(detail['my_bid'], isNull);
      // exact address is hidden until the quote is accepted
      expect(detail['address'], 'Kothrud');

      // ------------------------------------------------ worker quotes (idempotent on client_ref)
      final bid = await api.placeBid(jobId, 15000, 'ref-qa-1');
      expect(bid['status'], 'pending');
      expect(bid['price_inr'], 15000);
      final again = await api.placeBid(jobId, 15000, 'ref-qa-1');
      expect(again['id'], bid['id'], reason: 'same client_ref must not create a second bid');
      expect((await api.workerJob(jobId))['my_bid'], isNotNull);
      expect((await api.workerFeed()).firstWhere((j) => j['id'] == jobId)['already_bid'], true);
      await expectLater(api.placeBid(jobId, 50, 'ref-qa-x'), _apiError('err.validation'));

      // second worker undercuts below the minimum wage
      await signInAs(_sunil);
      await api.placeBid(jobId, 3000, 'ref-qa-2');

      // ------------------------------------------------ customer compares quotes
      await signInAs(_priya);
      var job = await api.customerJob(jobId);
      expect(job['status'], 'bidding');
      final bids = (job['bids'] as List).cast<Map>();
      expect(bids.length, 2);
      expect(bids.first['price_inr'], 3000, reason: 'sorted by price');
      expect((bids.first['fair'] as Map)['verdict'], 'below_min_wage');
      final good = bids.firstWhere((b) => b['price_inr'] == 15000);
      expect((good['fair'] as Map)['verdict'], 'fair');
      expect((good['worker'] as Map)['id'], ramesh.id);
      expect((job['work_items'] as List).length, 1);
      expect(job['assignment'], isNull);

      // ------------------------------------------------ accept -> escrow waits for payment
      final accepted = await api.acceptBid(jobId, good['id'] as String);
      final aid = accepted['assignment_id'] as String;
      job = await api.customerJob(jobId);
      expect(job['status'], 'assigned');
      var a = job['assignment'] as Map;
      expect(a['id'], aid);
      expect(a['price_inr'], 15000);
      expect((a['payment'] as Map)['escrow_state'], 'created');
      expect(a['tracking'], isNull);
      expect((job['bids'] as List).cast<Map>().firstWhere((b) => b['price_inr'] == 3000)['status'], 'rejected');
      expect(job['fee_inr'], 30);

      // the worker cannot start before the customer has paid
      await signInAs(_ramesh);
      await expectLater(api.startJourney(aid, null, null), _apiError('err.payment_pending'));
      await expectLater(api.markDone(aid, photos: [_photo]), _apiError('err.payment_pending'));
      final wAssign = (await api.assignments()).firstWhere((x) => x['id'] == aid);
      expect((wAssign['job'] as Map)['address'], 'Plot 12, Kothrud, Pune');
      expect(wAssign['customer_name'], priya.name);
      expect((await api.workerJob(jobId))['address'], 'Plot 12, Kothrud, Pune', reason: 'accepted worker sees the exact address');

      // ------------------------------------------------ customer pays into escrow
      await signInAs(_priya);
      final pay = await api.payJob(jobId, 'upi');
      expect(pay['escrow_state'], 'held');
      expect(pay['method'], 'upi');
      expect(pay['amount_inr'], 15030);
      expect(pay['platform_fee_inr'], 30);
      expect(pay['worker_payout_inr'], 15000);
      expect(pay['paid_at'], isNotNull);
      expect(pay['released_at'], isNull);
      expect(pay['ref'], startsWith('BC-'));

      // ------------------------------------------------ tracking: distance + ETA
      job = await api.customerJob(jobId);
      var tr = (job['assignment'] as Map)['tracking'] as Map?;
      expect(tr, isNotNull, reason: 'worker sets off right after payment in demo');
      expect(tr!['distance_km'] as num, inExclusiveRange(1.0, 5.0));
      expect(tr['eta_min'] as num, greaterThanOrEqualTo(1));
      expect(tr['arrived'], false);
      expect(tr['worker_lat'], isNotNull);
      expect(tr['worker_lng'], isNotNull);

      // worker taps "I'm on my way" explicitly (restarts the journey)
      await signInAs(_ramesh);
      await api.startJourney(aid, null, null);
      await signInAs(_priya);
      tr = ((await api.customerJob(jobId))['assignment'] as Map)['tracking'] as Map?;
      expect(tr!['distance_km'] as num, greaterThan(1.0));

      // ------------------------------------------------ worker checks in on site, then out, then done
      await signInAs(_priya);
      final startCode = ((await api.customerJob(jobId))['assignment'] as Map)['start_code']['code'] as String;
      await signInAs(_ramesh);
      final jobCard = await api.workerJob(jobId);
      final att = await api.attendance({
        'assignment_id': aid, 'kind': 'in', 'lat': jobCard['lat'], 'lng': jobCard['lng'], 'client_ref': 'att-qa-1', 'offline': false, 'selfie_key': null,
        'start_code': startCode,
      });
      expect(att['geofence_ok'], true);
      final dup = await api.attendance({
        'assignment_id': aid, 'kind': 'in', 'lat': jobCard['lat'], 'lng': jobCard['lng'], 'client_ref': 'att-qa-1', 'offline': false, 'start_code': startCode,
      });
      expect(dup['geofence_ok'], true);
      await api.attendance({'assignment_id': aid, 'kind': 'out', 'lat': jobCard['lat'], 'lng': jobCard['lng'], 'client_ref': 'att-qa-2'});
      await expectLater(api.markDone(aid), _apiError('err.proof_required'), reason: 'at least one proof photo is mandatory');
      await api.markDone(aid, photos: ['proof_after_1.jpg']);

      await signInAs(_priya);
      job = await api.customerJob(jobId);
      a = job['assignment'] as Map;
      expect(job['status'], 'in_progress');
      expect(a['worker_done_at'], isNotNull);
      expect((a['attendance'] as List).length, 1, reason: 'duplicate client_ref must not add a second check-in');
      expect(((a['attendance'] as List).first as Map)['out'], isNotNull);
      expect((a['tracking'] as Map)['arrived'], true);
      expect((a['tracking'] as Map)['eta_min'], 0);

      // ------------------------------------------------ release is BLOCKED before a rating
      await signInAs(_ramesh);
      final before = await api.earnings();
      await signInAs(_priya);
      // cannot rate (= cannot release) until the job is completed
      await expectLater(api.rateWorker(jobId, {'quality': 5, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 5}),
          _apiError('err.job_not_completed'));
      expect(((await api.customerJob(jobId))['assignment'] as Map)['payment']['escrow_state'], 'held');

      await api.completeJob(jobId);
      var row = (await api.customerJobs()).firstWhere((j) => j['id'] == jobId);
      expect(row['status'], 'completed');
      expect(row['needs_rating'], true, reason: 'completed + still held = rating is mandatory next');
      expect(row['payment_state'], 'held');
      expect((await api.payments()).firstWhere((p) => p['job_id'] == jobId)['escrow_state'], 'held');
      await signInAs(_ramesh);
      final held = await api.earnings();
      expect(held['total_earned_inr'], before['total_earned_inr'], reason: 'nothing released yet');
      expect(held['held_inr'], before['held_inr']);

      // ------------------------------------------------ multi-parameter rating releases the money
      await signInAs(_priya);
      await expectLater(api.rateWorker(jobId, {'quality': 0, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 5}), _apiError('err.validation'));
      expect(((await api.customerJob(jobId))['assignment'] as Map)['payment']['escrow_state'], 'held', reason: 'invalid rating must not release');
      final rated = await api.rateWorker(jobId, {'quality': 5, 'timeliness': 4, 'behaviour': 4, 'value_for_money': 5, 'comment': 'Neat work'});
      expect(rated['overall'], 4.5);
      expect((rated['payment'] as Map)['escrow_state'], 'released');
      expect((rated['payment'] as Map)['released_at'], isNotNull);
      await expectLater(api.rateWorker(jobId, {'quality': 5, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 5}), _apiError('err.already_rated'));

      row = (await api.customerJobs()).firstWhere((j) => j['id'] == jobId);
      expect(row['needs_rating'], false);
      expect(row['payment_state'], 'released');
      a = (await api.customerJob(jobId))['assignment'] as Map;
      final cr = (a['ratings'] as Map)['customer_to_worker'] as Map;
      expect([cr['quality'], cr['timeliness'], cr['behaviour'], cr['value_for_money']], [5, 4, 4, 5]);

      // ------------------------------------------------ receipt / payment record
      final payments = await api.payments();
      final rec = payments.firstWhere((p) => p['job_id'] == jobId);
      expect(rec['escrow_state'], 'released');
      expect(rec['amount_inr'], 15030);
      expect(rec['platform_fee_inr'], 30);
      expect(rec['worker_payout_inr'], 15000);
      expect(rec['ref'], pay['ref']);
      expect(rec['method'], 'upi');
      expect(rec['worker_name'], 'Ramesh Pawar');
      expect(rec['trades'], ['mason']);

      // ------------------------------------------------ worker side: money + rating arrived
      await signInAs(_ramesh);
      final after = await api.earnings();
      expect(after['total_earned_inr'] as num, (before['total_earned_inr'] as num) + 15000);
      expect(after['held_inr'] as num, (before['held_inr'] as num) - 15000, reason: 'escrow leaves "held" when released');
      // same-day pay: with a UPI ID on file the payout goes straight out, otherwise it waits in the balance
      expect((after['available_inr'] as num) - (before['available_inr'] as num), anyOf(0, 15000));
      final profile = await api.workerProfile();
      expect((profile['breakdown'] as Map)['count'], 25); // seed 24 + this one
      await api.rateCustomer(aid, 5, 4, 'Clear instructions');
      await expectLater(api.rateCustomer(aid, 5, 5, null), _apiError('err.already_rated'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cancel: free before a hire, refused once work started or finished', () async {
      await signInAs(_priya);
      final id = (await api.createJob(_jobBody()))['id'] as String;
      await api.cancelJob(id);
      expect((await api.customerJob(id))['status'], 'cancelled');
      expect((await api.cancelJob(id))['status'], 'cancelled', reason: 'a second tap is harmless');
      await signInAs('9100000002'); // Anil owns seeded j4 (work already in progress)
      await expectLater(api.cancelJob('j4'), _apiError('err.job_started_dispute'));
      await signInAs(_neha); // Neha owns seeded j5 (completed)
      await expectLater(api.cancelJob('j5'), _apiError('err.job_closed'));
      await expectLater(api.cancelJob('j4'), _apiError('err.not_found'), reason: 'not her job');
      final Json empty = _jobBody();
      empty['work_items'] = <Json>[];
      await expectLater(api.createJob(empty), _apiError('err.no_work_items'));
    });
  });

  group('chat', () {
    // Seeded open job j1 belongs to Priya (c1); Ramesh (w1) is a worker in the same marketplace.
    test('customer -> worker and worker -> customer, unread counts, read on open, no auto replies', () async {
      final priya = await signInAs(_priya);
      await signInAs(_ramesh);
      final ramesh = (await api.workerProfile())['id'] as String;
      await signInAs(_priya);
      expect(await api.chatThreads(), isEmpty);

      await api.sendChat('j1', ramesh, '  Namaste, kal aa sakte ho?  ');
      // sender sees it as "mine", never as unread
      var mineMsgs = await api.chat('j1', ramesh);
      expect(mineMsgs.length, 1);
      expect(mineMsgs.first['mine'], true);
      expect(mineMsgs.first['body'], 'Namaste, kal aa sakte ho?', reason: 'body is trimmed');
      expect((await api.chatThreads()).single['unread'], 0);

      // worker: thread with unread = 1, then opening marks it read
      await signInAs(_ramesh);
      var threads = await api.chatThreads();
      expect(threads.length, 1);
      var t = threads.single;
      expect(t['job_id'], 'j1');
      expect(t['with_user'], priya.id);
      expect(t['with_name'], 'Priya Sharma');
      expect(t['last_body'], 'Namaste, kal aa sakte ho?');
      expect(t['unread'], 1);
      expect(t['locality'], 'Kothrud');
      expect((await api.chatThreads()).single['unread'], 1, reason: 'listing threads must not mark them read');
      final seen = await api.chat('j1', priya.id);
      expect(seen.length, 1);
      expect(seen.first['mine'], false);
      expect(seen.first['body'], 'Namaste, kal aa sakte ho?');
      expect((await api.chatThreads()).single['unread'], 0);

      // worker replies
      await api.sendChat('j1', priya.id, 'Ji, subah 9 baje.');
      expect((await api.chat('j1', priya.id)).map((m) => m['mine']).toList(), [false, true]);

      // customer sees the reply (unread 1) and both messages in order
      await signInAs(_priya);
      threads = await api.chatThreads();
      t = threads.single;
      expect(t['with_user'], ramesh);
      expect(t['last_body'], 'Ji, subah 9 baje.');
      expect(t['unread'], 1);
      final convo = await api.chat('j1', ramesh);
      expect(convo.map((m) => m['body']).toList(), ['Namaste, kal aa sakte ho?', 'Ji, subah 9 baje.']);
      expect(convo.map((m) => m['mine']).toList(), [true, false]);
      expect((await api.chatThreads()).single['unread'], 0);

      // no fake auto-replies: running the marketplace simulation (feed/jobs reads) adds nothing
      await api.customerJobs();
      await signInAs(_ramesh);
      await api.workerFeed();
      await signInAs(_priya);
      expect((await api.chat('j1', ramesh)).length, 2);
    });

    test('threads are private to the two participants and per job', () async {
      await signInAs(_ramesh);
      final ramesh = (await api.workerProfile())['id'] as String;
      await signInAs(_priya);
      await api.sendChat('j1', ramesh, 'only for Ramesh');
      await api.sendChat('j6', ramesh, 'other job');
      expect((await api.chatThreads()).length, 2);
      await signInAs(_sunil);
      expect(await api.chatThreads(), isEmpty);
      expect(await api.chat('j1', 'c1'), isEmpty);
    });

    test('sending while signed out is rejected', () async {
      api.token = null;
      await expectLater(api.sendChat('j1', 'w1', 'hi'), _apiError('err.unauthorized'));
      expect(await api.chatThreads(), isEmpty);
    });
  });

  // ====================================================================================================
  // Completion disagreement flow, auto-confirm, hire release / refund rules, lifecycle edge cases.
  // Time is faked with DemoApi.demoSkipTime (it moves the stored timestamps back, like the backend tests do).
  // ====================================================================================================
  group('completion flow + edge cases', () {
    /// Priya posts a mason job; [worker] quotes 15000; Priya hires + (optionally) pays. Returns ids.
    Future<({String jobId, String aid})> hire({String worker = _ramesh, bool pay = true, String? rival}) async {
      await signInAs(_priya);
      final jobId = (await api.createJob(_jobBody()))['id'] as String;
      if (rival != null) {
        await signInAs(rival);
        await api.placeBid(jobId, 16000, 'rival-$jobId');
      }
      await signInAs(worker);
      await api.placeBid(jobId, 15000, 'ref-$worker-$jobId');
      await signInAs(_priya);
      final bids = ((await api.customerJob(jobId))['bids'] as List).cast<Map>();
      final mine = bids.firstWhere((b) => b['price_inr'] == 15000);
      final aid = (await api.acceptBid(jobId, mine['id'] as String))['assignment_id'] as String;
      if (pay) await api.payJob(jobId, 'upi');
      return (jobId: jobId, aid: aid);
    }

    Future<Map> asg(String jobId) async => (await api.customerJob(jobId))['assignment'] as Map;
    Future<String> escrow(String jobId) async => (await asg(jobId))['payment']['escrow_state'] as String;
    List<String> kinds(Map a) => [for (final e in (a['timeline'] as List).cast<Map>()) e['kind'] as String];

    Future<void> done(String worker, String aid, {String photo = 'after.jpg'}) async {
      await signInAs(worker);
      final jobId = ((await api.assignments()).firstWhere((x) => x['id'] == aid)['job'] as Map)['id'] as String;
      await startWithCode(worker, jobId, aid);
      await api.markDone(aid, photos: [photo], note: 'finished');
      await signInAs(_priya);
    }

    test('proof photo is mandatory; customer sees before and after; double tap = one event', () async {
      final h = await hire();
      await signInAs(_ramesh);
      await expectLater(api.markDone(h.aid), _apiError('err.proof_required'));
      await expectLater(api.markDone(h.aid, photos: ['  ']), _apiError('err.proof_required'));
      await expectLater(api.markDone(h.aid, photos: ['after_1.jpg']), _apiError('err.start_code_required'));
      await startWithCode(_ramesh, h.jobId, h.aid);
      await api.markDone(h.aid, photos: ['after_1.jpg'], note: 'Wall built');
      await api.markDone(h.aid, photos: ['after_1.jpg']); // double tap / offline replay
      await signInAs(_priya);
      final a = await asg(h.jobId);
      expect(a['proof_photos'], ['after_1.jpg']);
      expect(a['before_photos'], contains(_photo));
      expect(a['worker_done_note'], 'Wall built');
      expect(a['auto_confirm_at'], isNotNull);
      expect(a['auto_confirm_hours'], 48);
      expect(kinds(a), ['worker_done']);
      expect((await api.customerJobs()).firstWhere((j) => j['id'] == h.jobId)['needs_action'], true);
    });

    test('send back -> worker fixes -> customer confirms -> rates -> money released; timeline shows it all', () async {
      final h = await hire();
      await done(_ramesh, h.aid);
      final out = await api.sendBack(h.jobId, reasons: ['poor_quality', 'damage'], note: 'Tile cracked', photos: ['crack.jpg']);
      expect(out, {'outcome': 'rework', 'rework_count': 1, 'rework_left': 1});
      var a = await asg(h.jobId);
      expect(a['rework_open'], true);
      expect(a['worker_done_at'], isNull);
      expect(a['auto_confirm_at'], isNull, reason: 'the 48 h clock does not run while the worker owes a fix');
      expect((a['rework'] as Map)['reasons'], ['poor_quality', 'damage']);
      expect((a['rework'] as Map)['note'], 'Tile cracked');
      expect((a['rework'] as Map)['photos'], ['crack.jpg']);
      await expectLater(api.sendBack(h.jobId, reasons: ['other']), _apiError('err.nothing_to_send_back'));

      // the worker sees the red card data and must attach NEW proof
      await signInAs(_ramesh);
      final mine = (await api.assignments()).firstWhere((x) => x['id'] == h.aid);
      expect(mine['rework_open'], true);
      expect((mine['rework'] as Map)['reasons'], ['poor_quality', 'damage']);
      await expectLater(api.markDone(h.aid), _apiError('err.proof_required'));
      await api.markDone(h.aid, photos: ['fixed.jpg'], note: 'Replaced the tile');
      await signInAs(_priya);
      a = await asg(h.jobId);
      expect(a['rework_open'], false);
      expect(a['proof_photos'], ['fixed.jpg']);
      expect(a['rework_count'], 1);

      await api.completeJob(h.jobId);
      await api.completeJob(h.jobId); // idempotent
      expect(await escrow(h.jobId), 'held');
      await api.rateWorker(h.jobId, {'quality': 5, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 5});
      expect(await escrow(h.jobId), 'released');
      expect(kinds(await asg(h.jobId)), ['worker_done', 'rework_requested', 'worker_done', 'confirmed']);
      await expectLater(api.sendBack(h.jobId, reasons: ['other']), _apiError('err.nothing_to_send_back'));
    });

    test('send-back validation: needs a reason from the list, work must be claimed finished, not someone else\'s job', () async {
      final h = await hire();
      await expectLater(api.sendBack(h.jobId, reasons: ['incomplete']), _apiError('err.nothing_to_send_back'));
      await done(_ramesh, h.aid);
      await expectLater(api.sendBack(h.jobId, reasons: []), _apiError('err.validation'));
      await expectLater(api.sendBack(h.jobId, reasons: ['made_up']), _apiError('err.validation'));
      await expectLater(api.sendBack(h.jobId, reasons: ['other'], note: 'x' * 1001), _apiError('err.validation'));
      await signInAs(_neha);
      await expectLater(api.sendBack(h.jobId, reasons: ['other']), _apiError('err.not_found'));
      await signInAs(_priya);
      expect((await api.sendBack(h.jobId, reasons: ['not_came'])).containsKey('rework_left'), true);
    });

    test('3rd disagreement opens a dispute: nothing can move the money, support decides', () async {
      final h = await hire();
      for (var round = 1; round <= 2; round++) {
        await done(_ramesh, h.aid, photo: 'try$round.jpg');
        final r = await api.sendBack(h.jobId, reasons: ['incomplete'], note: 'round $round');
        expect(r['outcome'], 'rework');
        expect(r['rework_count'], round);
      }
      expect(((await asg(h.jobId))['rework_left']), 0);
      await done(_ramesh, h.aid, photo: 'try3.jpg');
      final third = await api.sendBack(h.jobId, reasons: ['incomplete'], note: 'still not done');
      expect(third['outcome'], 'disputed');
      expect((await api.customerJob(h.jobId))['status'], 'disputed');
      expect(await escrow(h.jobId), 'held');
      expect(kinds(await asg(h.jobId)).where((k) => k == 'rework_requested').length, 3);
      expect(kinds(await asg(h.jobId)).last, 'disputed');

      // frozen: confirm / send back / mark done / cancel / rate are all refused
      await expectLater(api.completeJob(h.jobId), _apiError('err.job_disputed'));
      await expectLater(api.sendBack(h.jobId, reasons: ['other']), _apiError('err.job_disputed'));
      await expectLater(api.cancelJob(h.jobId), _apiError('err.job_closed'));
      await expectLater(api.rateWorker(h.jobId, {'quality': 5, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 5}), _apiError('err.job_not_completed'));
      await signInAs(_ramesh);
      await expectLater(api.markDone(h.aid, photos: ['x.jpg']), _apiError('err.job_disputed'));
      await signInAs(_priya);
      await api.dispute(h.jobId, 'Please help us decide'); // a manual second report is harmless (same dispute)
      expect((await asg(h.jobId))['timeline'].where((e) => e['kind'] == 'disputed').length, 1);

      // demo: support decides after a day (50/50): worker gets half, customer the rest minus the fee
      await api.demoSkipTime(h.jobId, const Duration(hours: 24));
      expect((await api.customerJob(h.jobId))['status'], 'completed');
      final p = (await asg(h.jobId))['payment'] as Map;
      expect(p['escrow_state'], 'split');
      expect(p['worker_payout_inr'], 7500);
      expect(p['refund_inr'], 7500);
      expect(kinds(await asg(h.jobId)).last, 'dispute_resolved');
    });

    test('worker can report an unfair / silent customer; money stays frozen', () async {
      final h = await hire();
      await signInAs(_ramesh);
      await expectLater(api.workerDispute(h.aid, 'Customer is not answering'), _apiError('err.too_early_to_dispute'));
      await startWithCode(_ramesh, h.jobId, h.aid);
      await api.markDone(h.aid, photos: ['after.jpg']);
      await api.workerDispute(h.aid, 'Customer is not confirming');
      await api.workerDispute(h.aid, 'Customer is not confirming'); // idempotent
      await signInAs(_priya);
      expect((await api.customerJob(h.jobId))['status'], 'disputed');
      expect(await escrow(h.jobId), 'held');
    });

    test('customer silent for 48 h after "finished": auto-confirmed, paid, neutral rating that does not touch the average', () async {
      final h = await hire();
      await signInAs(_ramesh);
      final before = await api.workerProfile();
      final jobsBefore = (await api.workerPublic(before['id'] as String))['completed_jobs'] as int;
      await done(_ramesh, h.aid);
      await api.demoSkipTime(h.jobId, const Duration(hours: 47));
      var a = await asg(h.jobId);
      expect((await api.customerJob(h.jobId))['status'], 'in_progress', reason: '47 h: still waiting');
      expect(a['auto_confirmed'], false);
      expect(DateTime.parse(a['auto_confirm_at'] as String).isAfter(DateTime.now()), true, reason: 'about 1 h left');
      await api.demoSkipTime(h.jobId, const Duration(hours: 2));
      final j = await api.customerJob(h.jobId);
      a = j['assignment'] as Map;
      expect(j['status'], 'completed');
      expect(a['auto_confirmed'], true);
      expect((a['payment'] as Map)['escrow_state'], 'released');
      expect(((a['ratings'] as Map)['customer_to_worker'] as Map)['is_auto'], true);
      expect(kinds(a), ['worker_done', 'auto_confirmed']);
      await expectLater(api.rateWorker(h.jobId, {'quality': 1, 'timeliness': 1, 'behaviour': 1, 'value_for_money': 1}), _apiError('err.already_rated'));
      await expectLater(api.sendBack(h.jobId, reasons: ['other']), _apiError('err.nothing_to_send_back'));

      await signInAs(_ramesh);
      final after = await api.workerProfile();
      expect(after['rating'], before['rating']);
      expect(after['rating_count'], before['rating_count']);
      expect((after['history'] as List).any((x) => x['job_id'] == h.jobId), false, reason: 'auto rating is not shown as a review');
      expect((await api.workerPublic(before['id'] as String))['completed_jobs'], jobsBefore + 1);
      await api.rateCustomer(h.aid, 5, 3, null); // the worker may still rate the customer
    });

    test('no auto-confirm while the worker owes a fix or the job is in dispute', () async {
      final h = await hire();
      await done(_ramesh, h.aid);
      await api.sendBack(h.jobId, reasons: ['incomplete']);
      await api.demoSkipTime(h.jobId, const Duration(hours: 100));
      expect((await api.customerJob(h.jobId))['status'], 'in_progress');
      expect(await escrow(h.jobId), 'held');
    });

    test('customer confirmed but never rated for 48 h: neutral rating releases the money', () async {
      final h = await hire();
      await done(_ramesh, h.aid);
      await api.completeJob(h.jobId);
      expect(await escrow(h.jobId), 'held');
      await api.demoSkipTime(h.jobId, const Duration(hours: 49));
      expect(await escrow(h.jobId), 'released');
      expect(kinds(await asg(h.jobId)).last, 'auto_rated');
    });

    test('cancel after accepting but before paying voids the order; a stale pay screen cannot charge', () async {
      final h = await hire(pay: false);
      final out = await api.cancelJob(h.jobId);
      expect(out['status'], 'cancelled');
      expect(out['refunded_inr'], 0);
      expect((await api.customerJob(h.jobId))['status'], 'cancelled');
      expect((await api.customerJob(h.jobId))['assignment'], isNull);
      await expectLater(api.payJob(h.jobId, 'upi'), _apiError('err.hire_cancelled'));
      expect((await api.payments()).any((p) => p['job_id'] == h.jobId), false, reason: 'nothing was ever charged');
      await signInAs(_ramesh);
      expect((await api.assignments()).any((x) => x['id'] == h.aid), false);
    });

    test('cancel after paying but before the worker starts: full refund (quote + fee)', () async {
      final h = await hire();
      expect(await escrow(h.jobId), 'held');
      final out = await api.cancelJob(h.jobId);
      expect(out['refunded_inr'], 15030);
      expect((await api.customerJob(h.jobId))['status'], 'cancelled');
      final rec = (await api.payments()).firstWhere((p) => p['job_id'] == h.jobId);
      expect(rec['escrow_state'], 'refunded');
      expect(rec['refund_inr'], 15030);
      expect(rec['worker_payout_inr'], 0);
      expect((await api.cancelJob(h.jobId))['status'], 'cancelled', reason: 'double tap');
    });

    test('seeded paid-and-assigned job can be cancelled with a refund; seeded in-progress job needs support', () async {
      await signInAs(_priya);
      final out = await api.cancelJob('j3');
      expect(out['refunded_inr'] as num, greaterThan(0));
      await signInAs('9100000002');
      await expectLater(api.cancelJob('j4'), _apiError('err.job_started_dispute'));
    });

    test('cancel after work started goes through support (dispute), not cancel', () async {
      final h = await hire();
      await startWithCode(_ramesh, h.jobId, h.aid);
      final jc = await api.workerJob(h.jobId);
      await api.attendance({'assignment_id': h.aid, 'kind': 'in', 'lat': jc['lat'], 'lng': jc['lng'], 'client_ref': 'att-${h.aid}', 'offline': false});
      await signInAs(_priya);
      await expectLater(api.cancelJob(h.jobId), _apiError('err.job_started_dispute'));
      await expectLater(api.reopenJob(h.jobId), _apiError('err.job_started'));
      await expectLater(api.reportNoShow(h.jobId), _apiError('err.job_started'));
      expect(await escrow(h.jobId), 'held');
      await api.dispute(h.jobId, 'I want to stop this job');
      expect((await api.customerJob(h.jobId))['status'], 'disputed');
    });

    test('choose another worker: refund, earlier quotes return, new hire can be paid once', () async {
      final h = await hire(rival: _sunil);
      final out = await api.reopenJob(h.jobId);
      expect(out['status'], 'bidding');
      expect(out['refunded_inr'], 15030);
      expect((await api.reopenJob(h.jobId))['status'], 'bidding', reason: 'double tap');
      final j = await api.customerJob(h.jobId);
      expect(j['assignment'], isNull);
      final live = (j['bids'] as List).cast<Map>();
      expect(live.map((b) => b['price_inr']).toList(), [16000], reason: 'the rival quote is back, the old worker is gone');
      expect(live.single['status'], 'pending');
      await signInAs(_ramesh);
      expect((await api.assignments()).any((x) => x['id'] == h.aid), false);
      await signInAs(_priya);
      final second = (await api.acceptBid(h.jobId, live.single['id'] as String))['assignment_id'] as String;
      expect(second, isNot(h.aid));
      await api.payJob(h.jobId, 'upi');
      await api.payJob(h.jobId, 'upi'); // paying twice charges once
      expect(await escrow(h.jobId), 'held');
      final recs = (await api.payments()).where((p) => p['job_id'] == h.jobId).toList();
      expect(recs.map((p) => p['escrow_state']).toSet(), {'refunded', 'held'});
    });

    test('worker withdraws after being hired: customer refunded, job re-opens, strike if it was paid', () async {
      final h = await hire();
      await signInAs(_ramesh);
      final before = (await api.workerProfile())['strikes'] as int;
      final out = await api.withdrawHire(h.aid);
      expect(out['refunded_inr'], 15030);
      expect((await api.workerProfile())['strikes'], before + 1);
      expect((await api.assignments()).any((x) => x['id'] == h.aid), false);
      await api.withdrawHire(h.aid); // idempotent, no second strike
      expect((await api.workerProfile())['strikes'], before + 1);
      await signInAs(_priya);
      final j = await api.customerJob(h.jobId);
      expect(['open', 'bidding'].contains(j['status']), true);
      expect(j['assignment'], isNull);
      // an unpaid hire costs the worker nothing
      final u = await hire(pay: false, worker: _sunil);
      await signInAs(_sunil);
      final s0 = (await api.workerProfile())['strikes'] as int;
      await api.withdrawHire(u.aid);
      expect((await api.workerProfile())['strikes'], s0);
    });

    test('worker never arrives: report only after ETA + 60 min; refund, re-open, strike', () async {
      final h = await hire();
      await expectLater(api.reportNoShow(h.jobId), _apiError('err.no_show_too_early'));
      expect((await asg(h.jobId))['can_report_no_show'], false);
      await api.demoSkipTime(h.jobId, const Duration(hours: 2));
      expect((await asg(h.jobId))['can_report_no_show'], true);
      final out = await api.reportNoShow(h.jobId);
      expect(out['refunded_inr'], 15030);
      expect(['open', 'bidding'].contains(out['status']), true);
      await expectLater(api.reportNoShow(h.jobId), _apiError('err.hire_cancelled'));
      await signInAs(_ramesh);
      expect(((await api.workerProfile())['strikes'] as int) >= 1, true);
    });

    test('job date in the past or more than a year away is refused; today is fine', () async {
      await signInAs(_priya);
      await expectLater(api.createJob({..._jobBody(), 'start_date': _daysAhead(-2)}), _apiError('err.date_in_past'));
      await expectLater(api.createJob({..._jobBody(), 'start_date': _daysAhead(800)}), _apiError('err.date_too_far'));
      expect((await api.createJob({..._jobBody(), 'start_date': _daysAhead(0)}))['status'], 'open');
    });

    test('zero, negative and absurd prices are refused', () async {
      await signInAs(_priya);
      final id = (await api.createJob(_jobBody()))['id'] as String;
      await signInAs(_ramesh);
      for (final bad in [0, -500, 99, 10000001]) {
        await expectLater(api.placeBid(id, bad, 'bad-$bad'), _apiError('err.validation'));
      }
    });

    test('no quotes for 24 h: hint + nudge (once per 6 h)', () async {
      await signInAs(_priya);
      final id = (await api.createJob(_jobBody()))['id'] as String;
      expect((await api.customerJob(id))['no_quotes_24h'], false);
      await api.nudgeJob(id);
      await expectLater(api.nudgeJob(id), _apiError('err.nudge_too_soon'));
      expect((await api.customerJob(id))['nudged_at'], isNotNull);
      // seeded j1 is only 40 minutes old; seeded j6 has quotes: neither shows the hint
      expect((await api.customerJob('j1'))['no_quotes_24h'], false);
    });

    test('chat with a worker who was not hired becomes read-only after the hire; long text refused', () async {
      final h = await hire(rival: _sunil);
      final priya = await signInAs(_priya);
      await signInAs(_sunil);
      await expectLater(api.sendChat(h.jobId, priya.id, 'is the job still open?'), _apiError('err.chat_closed'));
      await signInAs(_ramesh);
      await api.sendChat(h.jobId, priya.id, 'Reaching at 9');
      await expectLater(api.sendChat(h.jobId, priya.id, 'y' * 1001), _apiError('err.validation'));
      await signInAs(_sunil);
      expect((await api.chat(h.jobId, priya.id)), isEmpty, reason: 'history is still readable');
    });

    test('account switched mid-flow: another account cannot act on this job', () async {
      final h = await hire();
      await done(_ramesh, h.aid);
      await signInAs(_neha); // someone else signs in on the same phone
      await expectLater(api.completeJob(h.jobId), _apiError('err.not_found'));
      await expectLater(api.sendBack(h.jobId, reasons: ['other']), _apiError('err.not_found'));
      await expectLater(api.cancelJob(h.jobId), _apiError('err.not_found'));
      await expectLater(api.reopenJob(h.jobId), _apiError('err.not_found'));
      await expectLater(api.dispute(h.jobId, 'not my job at all'), _apiError('err.not_found'));
      await signInAs(_sunil);
      await expectLater(api.markDone(h.aid, photos: ['x.jpg']), _apiError('err.not_found'));
      await expectLater(api.withdrawHire(h.aid), _apiError('err.not_found'));
      await signInAs(_priya);
      expect(await escrow(h.jobId), 'held');
    });

    test('rating already given: second submit is refused, money released once', () async {
      final h = await hire();
      await done(_ramesh, h.aid);
      await api.completeJob(h.jobId);
      final stars = {'quality': 4, 'timeliness': 4, 'behaviour': 4, 'value_for_money': 4};
      await api.rateWorker(h.jobId, stars);
      await expectLater(api.rateWorker(h.jobId, stars), _apiError('err.already_rated'));
      await signInAs(_ramesh);
      final e = await api.earnings();
      expect(((e['history'] as List).cast<Map>().where((r) => r['kind'] == 'job' && r['state'] == 'released').length) >= 1, true);
    });
  });

  // ================================================================ contractor team hiring, rules, scheduling
  group('post-job rules', () {
    test('needs two photos and a 50+ character description (server error codes)', () async {
      await signInAs(_priya);
      final onePhoto = _jobBody();
      ((onePhoto['work_items'] as List).first as Map)['photo_keys'] = [_photo];
      await expectLater(api.createJob(onePhoto), _apiError('err.photos_required'));
      final short = _jobBody();
      ((short['work_items'] as List).first as Map)['text_description'] = '   $_instruction   ';
      await expectLater(api.createJob(short), _apiError('err.description_short'));
      expect(((await api.createJob(_jobBody()))['id'] as String), isNotEmpty);
    });

    test('a start date in the past is rejected, tomorrow with a slot or exact time is stored', () async {
      await signInAs(_priya);
      final past = _jobBody()..['start_date'] = _inDays(-1);
      await expectLater(api.createJob(past), _apiError('err.date_in_past'));

      final t = DateTime.now().add(const Duration(days: 1));
      final at = DateTime(t.year, t.month, t.day, 9, 30);
      final body = _jobBody()
        ..['start_date'] = _inDays(1)
        ..['scheduled_for'] = at.toUtc().toIso8601String()
        ..['time_slot'] = 'exact';
      final id = (await api.createJob(body))['id'] as String;
      final row = (await api.customerJobs()).firstWhere((j) => j['id'] == id);
      expect(row['time_slot'], 'exact');
      expect(DateTime.parse(row['scheduled_for'] as String).toLocal().hour, 9);
      expect(DateTime.parse(row['scheduled_for'] as String).toLocal().minute, 30);
    });
  });

  group('fair range spread', () {
    test('low < median < high even when the inputs collapse (the "400 to 400" bug)', () {
      for (final (lo, md, hi) in [(400, 400, 400), (100, 100, 100), (50, 60, 60), (9000, 9000, 9000), (15000, 15000, 15500)]) {
        final (a, b, c) = DemoPricing.spread(lo, md, hi);
        expect(a, lessThan(b), reason: '$lo/$md/$hi -> $a/$b/$c');
        expect(b, lessThan(c), reason: '$lo/$md/$hi -> $a/$b/$c');
        expect(c, greaterThanOrEqualTo(a * 1.3 - 1e-6));
        expect(b, greaterThanOrEqualTo(a * 1.12 - 1e-6));
      }
    });

    test('a tiny job gets a real range', () async {
      final est = await api.priceEstimate(['helper'], 'Kothrud', texts: ['Carry two bags of cement upstairs'], city: 'Pune');
      for (final it in (est['items'] as List).cast<Map>()) {
        expect(it['low_inr'] as int, lessThan(it['median_inr'] as int));
        expect(it['median_inr'] as int, lessThan(it['high_inr'] as int));
      }
      expect(est['total_low_inr'] as int, lessThan(est['total_median_inr'] as int));
      expect(est['total_median_inr'] as int, lessThan(est['total_high_inr'] as int));
    });

    test('daily wage suggestion per trade is above the minimum wage and ordered', () async {
      final r = await api.wageSuggestion(['mason', 'helper'], 'Pune');
      expect((r['items'] as List).length, 2);
      for (final w in (r['items'] as List).cast<Map>()) {
        expect(w['low'] as int, greaterThanOrEqualTo(w['min_wage'] as int));
        expect(w['low'] as int, lessThan(w['median'] as int));
        expect(w['median'] as int, lessThan(w['high'] as int));
      }
    });
  });

  group('sample people', () {
    test('every trade has two workers and an open job in the feed', () async {
      await signInAs(_ramesh);
      for (final trade in ['mason', 'plumber', 'electrician', 'carpenter', 'painter', 'helper']) {
        final people = await api.browseWorkers(trade);
        expect(people.length, greaterThanOrEqualTo(2), reason: trade);
      }
      for (final (phone, trade, _, role) in demoAccounts) {
        if (role != 'worker') continue;
        await signInAs(phone);
        final feed = (await api.workerFeed()).cast<Map>();
        expect(feed, isNotEmpty, reason: 'no open job for $trade');
      }
    });

    test('demo accounts: one per trade plus a contractor and a customer, all sign in', () async {
      final roles = demoAccounts.map((a) => a.$4).toList();
      expect(roles.where((r) => r == 'worker').length, 6);
      expect(roles, containsAll(['customer', 'contractor']));
      expect(demoAccounts.map((a) => a.$2).toSet().length, demoAccounts.length);
      for (final (phone, _, name, role) in demoAccounts) {
        final u = await signInAs(phone);
        expect(u.name, name);
        expect(u.role, role == 'worker' ? 'worker' : 'customer');
        expect(u.isContractor, role == 'contractor');
      }
    });
  });

  group('contractor team hiring', () {
    Json teamBody({int headcount = 2, int days = 3, int wage = 1000}) => {
          ..._jobBody(),
          'kind': 'team',
          'address_text': 'Site 4, Hadapsar, Pune',
          'work_items': [
            {
              ...((_jobBody()['work_items'] as List).first as Map).cast<String, dynamic>(),
              'headcount': headcount,
              'days': days,
              'daily_wage_inr': wage,
            }
          ],
        };

    test('only a contractor can post a team job, and the wage cannot be below the minimum', () async {
      await signInAs(_priya);
      await expectLater(api.createJob(teamBody()), _apiError('err.contractor_only'));
      await signInAs('9100000002');
      await expectLater(api.createJob(teamBody(wage: 100)), _apiError('err.wage_below_minimum'));
    });

    test('post -> workers join -> accept several up to headcount -> one checkout -> attendance -> settle with refund', () async {
      await signInAs('9100000002');
      final jobId = (await api.createJob(teamBody()))['id'] as String;

      // workers see "2 masons needed" and join at the offered wage or quote their own
      await signInAs(_ramesh);
      final card = (await api.workerFeed()).cast<Map>().firstWhere((j) => j['id'] == jobId);
      expect(card['kind'], 'team');
      expect((card['team'] as Map)['headcount'], 2);
      final join = await api.placeBid(jobId, 950, 'tm-1');
      expect(join['price_inr'], 950);
      await signInAs(_sunil);
      await api.placeBid(jobId, 1000, 'tm-2');
      await signInAs('9200000011');
      await api.placeBid(jobId, 900, 'tm-3');

      await signInAs('9100000002');
      var job = await api.customerJob(jobId);
      final bids = (job['bids'] as List).cast<Map>();
      expect(bids.length, 3);
      final ramesh = bids.firstWhere((b) => b['price_inr'] == 950);
      final sunil = bids.firstWhere((b) => b['price_inr'] == 1000);
      final third = bids.firstWhere((b) => b['price_inr'] == 900);
      final a1 = (await api.acceptBid(jobId, ramesh['id'] as String))['assignment_id'] as String;
      final a2 = (await api.acceptBid(jobId, sunil['id'] as String))['assignment_id'] as String;
      expect(a1, isNot(a2));
      await expectLater(api.acceptBid(jobId, third['id'] as String), _apiError('err.team_full'));

      // a single checkout funds the whole team: wage x days + fee for each worker
      final pay = await api.payJob(jobId, 'upi');
      expect(pay['count'], 2);
      expect(pay['paid_inr'], (950 * 3 + 30) + (1000 * 3 + 30));
      expect(pay['escrow_state'], 'held');

      // attendance: Ramesh turns up, Sunil never does
      await signInAs('9100000002');
      final teamRows = ((await api.teamRoster(jobId))['workers'] as List).cast<Map>();
      final teamCode = (teamRows.firstWhere((r) => r['assignment_id'] == a1)['start_code'] as Map)['code'] as String;
      await signInAs(_ramesh);
      final site = await api.workerJob(jobId);
      await expectLater(api.attendance({'assignment_id': a1, 'kind': 'in', 'lat': site['lat'], 'lng': site['lng'], 'client_ref': 'tm-att-0', 'start_code': _wrongCode(teamCode)}),
          _apiError('err.start_code_invalid'));
      await api.attendance({'assignment_id': a1, 'kind': 'in', 'lat': site['lat'], 'lng': site['lng'], 'client_ref': 'tm-att-1', 'start_code': teamCode});

      await signInAs('9100000002');
      var roster = await api.teamRoster(jobId);
      expect((roster['summary'] as Map)['headcount'], 2);
      expect((roster['summary'] as Map)['filled'], 2);
      expect((roster['summary'] as Map)['present_today'], 1);
      final rows = (roster['workers'] as List).cast<Map>();
      expect(rows.firstWhere((r) => r['assignment_id'] == a1)['days_worked'], 1);
      expect(rows.firstWhere((r) => r['assignment_id'] == a2)['days_worked'], 0);

      // per-worker release after rating
      const stars = {'quality': 5, 'timeliness': 4, 'behaviour': 5, 'value_for_money': 4};
      final s1 = await api.settleTeamWorker(jobId, a1, stars);
      expect(s1['payout_inr'], 950);
      expect(s1['refund_inr'], 950 * 2, reason: 'unworked days go back to the contractor');
      expect((await api.customerJob(jobId))['status'], isNot('completed'), reason: 'one worker still unsettled');
      await expectLater(api.settleTeamWorker(jobId, a1, stars), _apiError('err.already_rated'));
      final s2 = await api.settleTeamWorker(jobId, a2, stars);
      expect(s2['payout_inr'], 0);
      expect(s2['refund_inr'], 1000 * 3 + 30, reason: 'no-show: everything incl. the fee comes back');
      expect((await api.customerJob(jobId))['status'], 'completed');
      roster = await api.teamRoster(jobId);
      expect((roster['workers'] as List).cast<Map>().every((r) => r['settled'] == true), true);

      // single-worker completion is not for teams
      await expectLater(api.completeJob(jobId), _apiError('err.team_use_roster'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('seeded contractor site shows headcount filled and today\'s attendance', () async {
      await signInAs('9100000002');
      final rows = (await api.customerJobs()).cast<Map>().where((j) => j['kind'] == 'team').toList();
      expect(rows.length, greaterThanOrEqualTo(2));
      final t1 = await api.teamRoster('t1');
      expect((t1['summary'] as Map)['headcount'], 6);
      expect((t1['summary'] as Map)['filled'], 3);
      expect(((t1['summary'] as Map)['present_today'] as int), greaterThanOrEqualTo(1));
    });
  });

  // ====================================================================================================
  // Trust & worker features: start code, share trip, police badge, warranty re-fix, same-day pay,
  // skill ladder + streak, hire again. Every rule is mirrored by backend/tests/test_trust.py.
  // ====================================================================================================
  group('trust & worker features', () {
    const stars = {'quality': 5, 'timeliness': 5, 'behaviour': 5, 'value_for_money': 5};

    Future<({String jobId, String aid})> hire({String worker = _ramesh}) async {
      await signInAs(_priya);
      final jobId = (await api.createJob(_jobBody()))['id'] as String;
      await signInAs(worker);
      await api.placeBid(jobId, 15000, 'ref-$worker-$jobId');
      await signInAs(_priya);
      final bids = ((await api.customerJob(jobId))['bids'] as List).cast<Map>();
      final aid = (await api.acceptBid(jobId, bids.firstWhere((b) => b['price_inr'] == 15000)['id'] as String))['assignment_id'] as String;
      await api.payJob(jobId, 'upi');
      return (jobId: jobId, aid: aid);
    }

    Future<Map> asg(String jobId) async => (await api.customerJob(jobId))['assignment'] as Map;

    /// hire -> start with the code -> done -> confirm -> rate (releases the money). Ends signed in as Priya.
    Future<({String jobId, String aid})> finished({String worker = _ramesh}) async {
      final h = await hire(worker: worker);
      await startWithCode(worker, h.jobId, h.aid);
      await api.markDone(h.aid, photos: ['after.jpg']);
      await signInAs(_priya);
      await api.completeJob(h.jobId);
      await api.rateWorker(h.jobId, stars);
      return h;
    }

    // ------------------------------------------------------------------ 1. start-work code
    test('start code: wrong code, lock after five misses, right code starts the work', () async {
      final h = await hire();
      final code = ((await asg(h.jobId))['start_code'] as Map)['code'] as String;
      expect(code, matches(RegExp(r'^\d{4}$')));
      expect(((await asg(h.jobId))['start_code'] as Map)['needed'], true);

      await signInAs(_ramesh);
      final mine = (await api.assignments()).firstWhere((x) => x['id'] == h.aid);
      expect(mine['start_code_state'], 'needed');
      expect(mine.toString(), isNot(contains(code)), reason: 'the code is never sent to the worker');
      await expectLater(api.startWork(h.aid), _apiError('err.start_code_required'));
      final bad = _wrongCode(code);
      for (var i = 0; i < 4; i++) {
        await expectLater(api.startWork(h.aid, code: bad), _apiError('err.start_code_invalid'));
      }
      await expectLater(api.startWork(h.aid, code: bad), _apiError('err.start_code_locked'));
      await expectLater(api.startWork(h.aid, code: code), _apiError('err.start_code_locked'), reason: 'locked even for the right code');
      expect((await api.assignments()).firstWhere((x) => x['id'] == h.aid)['start_code_state'], 'locked');
      await signInAs(_priya);
      expect(((await asg(h.jobId))['start_code'] as Map)['locked_until'], isNotNull);
      expect((await api.customerJob(h.jobId))['status'], 'assigned', reason: 'wrong tries never start the work');
    });

    test('start code: the right code starts the work and hides the code', () async {
      final h = await hire();
      await startWithCode(_ramesh, h.jobId, h.aid);
      await signInAs(_priya);
      expect((await api.customerJob(h.jobId))['status'], 'in_progress');
      expect(((await asg(h.jobId))['start_code'] as Map)['needed'], false);
      expect(((await asg(h.jobId))['start_code'] as Map)['code'], isNull);
    });

    test('start code: check-in needs it online; offline check-in is pending until the code is entered', () async {
      final h = await hire();
      await signInAs(_priya);
      final code = ((await asg(h.jobId))['start_code'] as Map)['code'] as String;
      await signInAs(_ramesh);
      final jc = await api.workerJob(h.jobId);
      Json body(String ref, {String? c, bool offline = false}) =>
          {'assignment_id': h.aid, 'kind': 'in', 'lat': jc['lat'], 'lng': jc['lng'], 'client_ref': ref, 'offline': offline, if (c != null) 'start_code': c};
      await expectLater(api.attendance(body('att-nc')), _apiError('err.start_code_required'));
      await expectLater(api.attendance(body('att-bad', c: _wrongCode(code))), _apiError('err.start_code_invalid'));
      // typed without a connection and left out: stored as pending, work does NOT start
      final off = await api.attendance(body('att-off', offline: true));
      expect(off['code_status'], 'pending');
      await expectLater(api.markDone(h.aid, photos: ['after.jpg']), _apiError('err.start_code_required'));
      expect((await api.assignments()).firstWhere((x) => x['id'] == h.aid)['start_code_state'], 'pending');
      // back online: the worker enters the code and the pending check-in is verified
      await api.startWork(h.aid, code: code);
      await api.markDone(h.aid, photos: ['after.jpg']);
      await signInAs(_priya);
      expect((await asg(h.jobId))['worker_done_at'], isNotNull);
    });

    test('start code: an offline wrong code is marked failed on sync and never starts the work', () async {
      final h = await hire();
      await signInAs(_priya);
      final code = ((await asg(h.jobId))['start_code'] as Map)['code'] as String;
      await signInAs(_ramesh);
      final jc = await api.workerJob(h.jobId);
      final r = await api.attendance({'assignment_id': h.aid, 'kind': 'in', 'lat': jc['lat'], 'lng': jc['lng'], 'client_ref': 'att-off-bad', 'offline': true, 'start_code': _wrongCode(code)});
      expect(r['code_status'], 'failed');
      await expectLater(api.markDone(h.aid, photos: ['after.jpg']), _apiError('err.start_code_required'));
    });

    // ------------------------------------------------------------------ 2. share live trip
    test('share trip: token + link + masked phone while on the way; refused once work started', () async {
      final h = await hire();
      final t = await api.shareTrip(h.jobId);
      expect(t['url'], startsWith('https://buildcrew.app/t/'));
      expect(t['url'], endsWith(t['token'] as String));
      expect(t['worker_name'], 'Ramesh Pawar');
      expect(t['trade'], 'mason');
      expect(t['police_verified'], true);
      expect(t['worker_phone_masked'], contains('*'));
      expect(t['worker_phone_masked'], isNot(contains(_ramesh)));
      expect((await api.shareTrip(h.jobId))['token'], t['token'], reason: 'one live link per trip');
      await startWithCode(_ramesh, h.jobId, h.aid);
      await signInAs(_priya);
      await expectLater(api.shareTrip(h.jobId), _apiError('err.trip_not_active'));
      await signInAs(_neha);
      await expectLater(api.shareTrip(h.jobId), _apiError('err.not_found'));
    });

    // ------------------------------------------------------------------ 3. police-verified badge
    test('police verification: needs KYC L1, pending after the request, seeded shields show in browse', () async {
      await signInAs(_sunil);
      final before = await api.workerProfile();
      expect((before['police'] as Map)['status'], 'pending', reason: 'seeded: Sunil already asked');
      expect((await api.requestPoliceVerification())['status'], 'pending', reason: 'asking twice is harmless');
      await signInAs('9200000004'); // Gopal: no request yet
      expect(((await api.workerProfile())['police'] as Map)['status'], 'none');
      expect((await api.requestPoliceVerification())['status'], 'pending');
      expect(((await api.workerProfile())['police'] as Map)['status'], 'pending');
      expect((await api.workerProfile())['police_verified'], false);

      await signInAs(_priya);
      final rows = await api.browseWorkers('mason');
      final ramesh = rows.firstWhere((r) => r['name'] == 'Ramesh Pawar');
      expect(ramesh['police_verified'], true);
      expect(ramesh['level'], 'skilled');
    });

    // ------------------------------------------------------------------ 4. work warranty
    test('warranty: re-fix is free, one open at a time, max two, then limit; expires with the days', () async {
      final h = await finished();
      final w = (await asg(h.jobId))['warranty'] as Map;
      expect(w['days'], 15);
      expect(w['active'], true);
      expect(w['can_request'], true);
      await expectLater(api.requestRefix(h.jobId, reason: 'x', photos: ['a.jpg']), _apiError('err.validation'));
      await expectLater(api.requestRefix(h.jobId, reason: 'Crack is back on the wall'), _apiError('err.proof_required'));

      Future<({String jobId, String aid})> refix(String why) async {
        final r = await api.requestRefix(h.jobId, reason: why, photos: ['crack.jpg']);
        return (jobId: r['job_id'] as String, aid: r['assignment_id'] as String);
      }

      final r1 = await refix('Crack is back on the wall');
      final job = await api.customerJob(r1.jobId);
      expect(job['status'], 'assigned');
      expect((job['assignment'] as Map)['kind'], 'refix');
      expect(((job['assignment'] as Map)['refix'] as Map)['parent_job_id'], h.jobId);
      expect(((job['assignment'] as Map)['payment']), isNull, reason: 're-fix is free: no payment');
      expect((await api.customerJobs()).firstWhere((j) => j['id'] == r1.jobId)['refix'], true);
      expect((await asg(h.jobId))['warranty']['open_job_id'], r1.jobId);
      await expectLater(api.requestRefix(h.jobId, reason: 'Another crack appeared', photos: ['c2.jpg']), _apiError('err.refix_open'));
      await expectLater(api.rateWorker(r1.jobId, stars), _apiError('err.validation'), reason: 'a re-fix is not rated');

      Future<void> finishRefix(({String jobId, String aid}) r) async {
        await startWithCode(_ramesh, r.jobId, r.aid);
        await api.markDone(r.aid, photos: ['fixed.jpg']);
        await signInAs(_priya);
        await api.demoSkipTime(r.jobId, const Duration(hours: 49)); // auto-confirms after 48 h
        expect((await api.customerJob(r.jobId))['status'], 'completed');
      }

      await finishRefix(r1);
      final r2 = await refix('Corner is loose again');
      await finishRefix(r2);
      await expectLater(api.requestRefix(h.jobId, reason: 'Third time now', photos: ['c3.jpg']), _apiError('err.refix_limit'));
      expect((await asg(h.jobId))['warranty']['can_request'], false);

      // the guarantee runs out after the trade's days
      final h2 = await finished();
      await api.demoSkipTime(h2.jobId, const Duration(days: 16));
      expect(((await asg(h2.jobId))['warranty'] as Map)['active'], false);
      await expectLater(api.requestRefix(h2.jobId, reason: 'Crack is back on the wall', photos: ['a.jpg']), _apiError('err.warranty_expired'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('warranty: only when the money was released; only the owner can ask; counts on the worker record', () async {
      final h = await hire();
      await expectLater(api.requestRefix(h.jobId, reason: 'Crack is back on the wall', photos: ['a.jpg']), _apiError('err.job_not_completed'));
      final done = await finished();
      await signInAs(_neha);
      await expectLater(api.requestRefix(done.jobId, reason: 'Crack is back on the wall', photos: ['a.jpg']), _apiError('err.not_found'));
      await signInAs(_ramesh);
      final before = (await api.workerProfile())['warranty_record'] as Map;
      await signInAs(_priya);
      await api.requestRefix(done.jobId, reason: 'Crack is back on the wall', photos: ['a.jpg']);
      await signInAs(_ramesh);
      final after = (await api.workerProfile())['warranty_record'] as Map;
      expect(after['refixes'], (before['refixes'] as int) + 1);
    });

    // ------------------------------------------------------------------ 5. same-day pay
    test('same-day pay: release sends the money to UPI (processing, then paid) and notifies once', () async {
      await signInAs(_ramesh);
      final before = await api.earnings();
      final beforeToday = ((before['paid_today'] as Map)['total_inr'] as num);
      final h = await finished();
      await signInAs(_ramesh);
      final notices = await api.workerNotices();
      expect(notices.length, 1);
      expect(notices.first['kind'], 'payout_sent');
      expect(notices.first['amount_inr'], 15000);
      expect(notices.first['upi'], 'ra****@okaxis');
      expect(notices.first['state'], 'processing');
      final e = await api.earnings();
      expect(((e['paid_today'] as Map)['total_inr'] as num) - beforeToday, 15000);
      expect(((e['paid_today'] as Map)['items'] as List).cast<Map>().any((x) => x['state'] == 'processing'), true);
      expect(e['nudge_add_upi'], false);
      await api.ackNotices([notices.first['id'] as String]);
      expect(await api.workerNotices(), isEmpty, reason: 'acknowledged notices do not come back');
      await Future<void>.delayed(DemoApi.payoutSettle + const Duration(milliseconds: 300));
      await api.workerNotices(); // settles processing payouts
      final e2 = await api.earnings();
      expect(((e2['paid_today'] as Map)['items'] as List).cast<Map>().every((x) => x['state'] == 'paid'), true);
      expect(h.jobId, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('same-day pay: seeded plumber already has a "paid today" row', () async {
      await signInAs('9200000003');
      final e = await api.earnings();
      final items = ((e['paid_today'] as Map)['items'] as List).cast<Map>();
      expect(items, isNotEmpty);
      expect(items.first['amount_inr'], 1300);
      expect(items.first['upi'], 'im****@okaxis');
    });

    // ------------------------------------------------------------------ 6. skill ladder + streak
    test('levels: seeded Ramesh is Skilled with a streak; the ladder and fair-wage multipliers', () async {
      await signInAs(_ramesh);
      final p = await api.workerProfile();
      final lc = p['level_card'] as Map;
      expect(lc['code'], 'skilled');
      expect((lc['next'] as Map)['code'], 'master');
      expect(lc['fair_multiplier'], 1.1);
      expect(lc['progress'] as num, inInclusiveRange(0, 1));
      expect((p['streak'] as Map)['weeks'] as int, greaterThanOrEqualTo(1));

      expect(DemoLevels.levelFor(0, 0, 0)['code'], 'helper');
      expect(DemoLevels.levelFor(5, 4.0, 0)['code'], 'semi_skilled');
      expect(DemoLevels.levelFor(5, 3.9, 0)['code'], 'helper');
      expect(DemoLevels.levelFor(20, 4.3, 0)['code'], 'skilled');
      expect(DemoLevels.levelFor(60, 4.6, 0)['code'], 'master');
      expect(DemoLevels.levelFor(60, 4.6, 6)['code'], 'skilled', reason: 'too many re-fixes: 10% >= 5%');
      expect(DemoLevels.levelFor(60, 4.6, 0)['fair_multiplier'], 1.25);
      final jan = DateTime(2026, 1, 5);
      expect(DemoLevels.streakFromWeeks({DemoLevels.weekKey(jan), DemoLevels.weekKey(jan.subtract(const Duration(days: 7)))}, jan)['weeks'], 2);
      expect(DemoLevels.streakFromWeeks({DemoLevels.weekKey(jan.subtract(const Duration(days: 14)))}, jan)['weeks'], 0, reason: 'a missed week breaks it');
    });

    test('levels: the suggested range scales with level but the minimum wage floor never moves', () async {
      await signInAs(_ramesh);
      final jobs = await api.workerFeed();
      expect(jobs, isNotEmpty);
      final id = jobs.first['id'] as String;
      final detail = await api.workerJob(id);
      expect(detail['level'], 'skilled');
      expect(detail['level_multiplier'], 1.1);
      final fr = detail['fair_range'] as Map?;
      if (fr != null) {
        expect(fr['low'] as num, lessThanOrEqualTo(fr['high'] as num));
        if (fr['min_wage_total'] != null) expect(fr['min_wage_total'] as num, lessThanOrEqualTo(fr['low'] as num), reason: 'the legal minimum is never scaled');
      }
    });

    test('streak: public profile and worker profile show the weeks', () async {
      await signInAs(_priya);
      final pub = await api.workerPublic('w1');
      expect((pub['level_card'] as Map)['code'], 'skilled');
      expect((pub['streak'] as Map)['weeks'] as int, greaterThanOrEqualTo(1));
      expect((pub['warranty_record'] as Map)['refixes'], 1);
    });

    // ------------------------------------------------------------------ 10. hire again
    test('hire again: favourites list the worker Priya rated well, the draft is prefilled', () async {
      await signInAs(_priya);
      final favs = await api.favourites();
      expect(favs, isNotEmpty);
      final imran = favs.firstWhere((f) => f['name'] == 'Imran Shaikh');
      expect(imran['last_trade'], 'plumber');
      expect(imran['jobs_together'] as int, greaterThanOrEqualTo(1));
      final draft = await api.rebookDraft(workerId: imran['id'] as String);
      expect((draft['worker'] as Map)['name'], 'Imran Shaikh');
      final item = (draft['items'] as List).cast<Map>().first;
      expect(item['trade'], 'plumber');
      expect((item['text_description'] as String), isNotEmpty);
      expect(draft['address_text'], isNotEmpty);
      final byJob = await api.rebookDraft(jobId: 'jw');
      expect((byJob['worker'] as Map)['name'], 'Imran Shaikh');
      await signInAs(_neha);
      await expectLater(api.rebookDraft(jobId: 'jw'), _apiError('err.not_found'));
    });

    test('hire again: completed bookings point to the worker', () async {
      await signInAs(_priya);
      final rows = await api.customerJobs();
      final jw = rows.firstWhere((j) => j['id'] == 'jw');
      expect(jw['hire_again_worker_id'], 'w3');
    });

    test('direct request: only the chosen worker sees it and can quote; declining opens it to everyone', () async {
      await signInAs(_priya);
      final mine = (await api.customerJobs()).firstWhere((j) => j['id'] == 'jd');
      expect(mine['direct_state'], 'pending');
      expect(mine['direct_worker'], 'Ramesh Pawar');

      await signInAs(_ramesh);
      final feed = await api.workerFeed();
      expect(feed.first['id'], 'jd', reason: 'direct requests come first');
      expect((feed.first['direct'] as Map)['customer_name'], 'Priya Sharma');

      await signInAs(_sunil); // another mason
      expect((await api.workerFeed()).any((r) => r['id'] == 'jd'), false);
      await expectLater(api.placeBid('jd', 3000, 'ref-sunil-jd'), _apiError('err.direct_only'));

      await signInAs(_ramesh);
      await api.declineDirect('jd');
      await signInAs(_priya);
      expect((await api.customerJobs()).firstWhere((j) => j['id'] == 'jd')['direct_state'], 'declined');
      await signInAs(_sunil);
      expect((await api.workerFeed()).any((r) => r['id'] == 'jd'), true, reason: 'open to all once declined');
      await signInAs(_neha);
      await expectLater(api.declineDirect('jd'), _apiError('err.forbidden'));
    });

    test('direct request: a new job "send to X first" is exclusive to that worker', () async {
      await signInAs(_priya);
      final body = _jobBody()..['direct_worker_id'] = 'w1';
      final id = (await api.createJob(body))['id'] as String;
      await signInAs(_sunil);
      expect((await api.workerFeed()).any((r) => r['id'] == id), false);
      await expectLater(api.placeBid(id, 15000, 'ref-sunil-direct'), _apiError('err.direct_only'));
      await signInAs(_ramesh);
      final row = (await api.workerFeed()).firstWhere((r) => r['id'] == id);
      expect(row['direct'], isNotNull);
      await api.placeBid(id, 15000, 'ref-ramesh-direct');
    });
  });

  group('sync + notifications', () {
    Future<String> postJobAsPriya() async {
      await signInAs(_priya);
      return (await api.createJob(_jobBody()))['id'] as String;
    }

    test('sync: baseline cursor, quiet polls change nothing, a write bumps the revision', () async {
      await signInAs(_priya);
      final b = await api.sync(null);
      expect(b['full'], true);
      final settled = (await api.sync(b['cursor'] as int))['cursor'] as int;
      final quiet = await api.sync(settled);
      expect(quiet['cursor'], settled);
      expect((quiet['changed'] as Map)['all'], false);
      // reads must not tick the revision
      await api.customerJobs();
      await api.unreadNotifications();
      expect((await api.sync(settled))['cursor'], settled);
      // a real write does
      await api.createJob(_jobBody());
      final after = await api.sync(settled);
      expect(after['cursor'] as int, greaterThan(settled));
      expect((after['changed'] as Map)['all'], true);
    });

    test('notifications: new quote -> unread count -> mark read; accept and chat notify the other side', () async {
      final jobId = await postJobAsPriya();
      final priya = (await signInAs(_priya)).id;
      expect(await api.unreadNotifications(), 0);
      final cursor = (await api.sync(null))['cursor'] as int;

      await signInAs(_ramesh);
      final bid = await api.placeBid(jobId, 15000, 'ref-sync-1');

      await signInAs(_priya);
      expect(await api.unreadNotifications(), 1);
      final s = await api.sync(cursor);
      expect(s['unread'], 1);
      expect((s['changed'] as Map)['notifications'], 1);
      var list = await api.notifications();
      expect(list.single['kind'], 'new_quote');
      expect(list.single['read'], false);
      expect(list.single['link'], '/job/$jobId');
      expect((list.single['title'] as String).isNotEmpty, true);
      await api.markNotificationsRead([list.single['id'] as String]);
      expect(await api.unreadNotifications(), 0);
      expect((await api.notifications()).single['read'], true);

      // accepting tells the worker; chatting tells the other person; unread is per user
      await api.acceptBid(jobId, bid['id'] as String);
      await signInAs(_ramesh);
      list = await api.notifications();
      expect(list.first['kind'], 'quote_accepted');
      expect(await api.unreadNotifications(), 1);
      final ramesh = (await api.workerProfile())['id'] as String;
      await signInAs(_priya);
      await api.sendChat(jobId, ramesh, 'Kal 9 baje aa jao');
      await signInAs(_ramesh);
      list = await api.notifications();
      expect(list.first['kind'], 'chat_message');
      expect(list.first['body'], 'Kal 9 baje aa jao');
      expect(list.first['link'], '/chat/$jobId/$priya');
      expect(await api.unreadNotifications(), 2);
      await api.markNotificationsRead(); // everything
      expect(await api.unreadNotifications(), 0);
      await signInAs(_priya); // the customer's own list is untouched by the worker's read-all
      expect((await api.notifications()).any((n) => n['kind'] == 'new_quote'), true);
    });

    test('SyncService: baseline, revision ticks on a change, unread count, boost switches the interval', () async {
      final jobId = await postJobAsPriya();
      final svc = SyncService(api)..start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(svc.healthy, true);
      final base = svc.revision.value;
      expect(base, greaterThan(0));
      expect(svc.interval, SyncService.idle);
      final holder = Object();
      svc.boost(holder);
      expect(svc.interval, SyncService.live);
      svc.release(holder);
      expect(svc.interval, SyncService.idle);

      await signInAs(_ramesh);
      await api.placeBid(jobId, 15000, 'ref-sync-svc');
      await signInAs(_priya);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await svc.pollNow();
      expect(svc.revision.value, greaterThan(base));
      expect(svc.unread.value, 1);
      expect(svc.last.notifications, 1);
      svc.stop();
      expect(SyncService.current, isNull);
    });
  });
}
