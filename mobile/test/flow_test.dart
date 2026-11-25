import 'package:buildcrew/core/api.dart';
import 'package:buildcrew/core/demo_api.dart';
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

late DemoApi api;

Future<SessionUser> signInAs(String phone) async {
  final r = await api.verifyOtp(phone, '123456', role: phone.startsWith('91') ? 'customer' : 'worker', lang: 'en');
  return r.user;
}

Json _jobBody() => {
      'location_lat': 18.5074,
      'location_lng': 73.8077,
      'address_text': 'Plot 12, Kothrud, Pune',
      'city': 'Pune',
      'locality': 'Kothrud',
      'start_date': '2026-12-01',
      'work_items': [
        {
          'trade': 'mason',
          'description_language': 'en',
          'text_description': _instruction,
          'photo_keys': [_photo],
          'transcript': null,
          'audio_key': null,
        }
      ],
    };

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
      expect(item['photos'], [_photo]);
      expect(item['text'], _instruction);
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
      await expectLater(api.markDone(aid), _apiError('err.payment_pending'));
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
      await signInAs(_ramesh);
      final jobCard = await api.workerJob(jobId);
      final att = await api.attendance({
        'assignment_id': aid, 'kind': 'in', 'lat': jobCard['lat'], 'lng': jobCard['lng'], 'client_ref': 'att-qa-1', 'offline': false, 'selfie_key': null,
      });
      expect(att['geofence_ok'], true);
      final dup = await api.attendance({
        'assignment_id': aid, 'kind': 'in', 'lat': jobCard['lat'], 'lng': jobCard['lng'], 'client_ref': 'att-qa-1', 'offline': false,
      });
      expect(dup['geofence_ok'], true);
      await api.attendance({'assignment_id': aid, 'kind': 'out', 'lat': jobCard['lat'], 'lng': jobCard['lng'], 'client_ref': 'att-qa-2'});
      await api.markDone(aid);

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
      expect(after['available_inr'] as num, (before['available_inr'] as num) + 15000);
      final profile = await api.workerProfile();
      expect((profile['breakdown'] as Map)['count'], 25); // seed 24 + this one
      await api.rateCustomer(aid, 5, 4, 'Clear instructions');
      await expectLater(api.rateCustomer(aid, 5, 5, null), _apiError('err.already_rated'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cancel is only possible before a worker is hired', () async {
      await signInAs(_priya);
      final id = (await api.createJob(_jobBody()))['id'] as String;
      await api.cancelJob(id);
      expect((await api.customerJob(id))['status'], 'cancelled');
      await expectLater(api.cancelJob('j3'), _apiError('err.job_closed')); // seeded, already assigned
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
}
