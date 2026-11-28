import 'package:buildcrew/core/api.dart';
import 'package:buildcrew/core/demo_api.dart';
import 'package:buildcrew/features/customer/job_templates.dart';
import 'package:buildcrew/features/customer/post_job.dart' show minDescription;
import 'package:buildcrew/l10n/gen/app_localizations.dart';
import 'package:buildcrew/widgets/common.dart';
import 'package:buildcrew/widgets/job_progress.dart';
import 'package:buildcrew/widgets/schedule.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Customer UX: templates, money style, human dates, job progress, best-match scoring (mirror of backend matching.py).
const _neha = '9100000003'; // customer with seeded job j2 (three quotes)
const _priya = '9100000001'; // customer: j3 is hired and paid

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('job templates', () {
    test('every trade has 4+ templates (5-7 for most); ids are unique; Other has no starter text', () {
      expect({for (final t in jobTemplates) t.id}.length, jobTemplates.length);
      for (final trade in const ['mason', 'plumber', 'electrician', 'carpenter', 'painter', 'helper']) {
        final n = templatesFor(trade).length;
        expect(n, greaterThanOrEqualTo(4), reason: trade);
        expect(n, lessThanOrEqualTo(7), reason: trade);
      }
      expect(templatesFor('carpenter').map((t) => t.id), containsAll(['DoorRepair', 'Furniture', 'Cupboard', 'NewShelf', 'WindowFrame', 'ModularKitchen']));
      expect(templatesFor('nobody'), isEmpty);
      expect(templateById(otherJobId), isNull);
    });

    test('each template has a >= 50 character starter text and a title in English, Hindi and Hinglish', () async {
      // Hinglish is the en_IN locale (Roman-script Hindi); `en` and `hi` are the other two launch texts.
      for (final loc in const [Locale('en'), Locale('hi'), Locale('en', 'IN')]) {
        final l = await L.delegate.load(loc);
        for (final t in jobTemplates) {
          final text = templateText(l, t.id).trim();
          expect(text.length, greaterThanOrEqualTo(minDescription), reason: '${t.id} $loc');
          expect(text.length, lessThanOrEqualTo(300), reason: '${t.id} $loc fits the 300 character box');
          expect(templateTitle(l, t.id).trim(), isNotEmpty, reason: '${t.id} $loc');
        }
        // "Other work": a title, but no starter text (the customer describes it on the next step)
        expect(templateText(l, otherJobId), isEmpty);
        expect(templateTitle(l, otherJobId), l.pjOtherWork);
      }
      final en = await L.delegate.load(const Locale('en'));
      final hing = await L.delegate.load(const Locale('en', 'IN'));
      expect(templateText(hing, 'Cupboard'), isNot(templateText(en, 'Cupboard')), reason: 'Hinglish has its own text');
      expect(templateLang(await L.delegate.load(const Locale('hi'))), 'hi');
      expect(templateLang(await L.delegate.load(const Locale('ta'))), 'en');
      expect(templateLang(hing), 'en');
    });
  });

  group('money', () {
    test('one format: rupee sign, Indian grouping, ranges collapse when equal', () {
      expect(const MoneyText(1234567).label, '₹12,34,567');
      expect(const MoneyText(0).label, '₹0');
      expect(const MoneyText(null).label, '₹0');
      expect(const MoneyText.range(500, 700).label, '₹500 – ₹700');
      expect(const MoneyText.range(500, 500).label, '₹500');
      expect(MoneyText.fontSizeOf(MoneySize.s) < MoneyText.fontSizeOf(MoneySize.m), true);
      expect(MoneyText.fontSizeOf(MoneySize.l) < MoneyText.fontSizeOf(MoneySize.xl), true);
    });
  });

  group('human dates', () {
    test('today / tomorrow / weekday + day + month, never ISO', () async {
      final l = await L.delegate.load(const Locale('en'));
      final now = DateTime.now();
      final at9 = DateTime(now.year, now.month, now.day, 9);
      expect(scheduleText(l, at9.toUtc().toIso8601String(), null), 'Today, 9 AM');
      final t = DateTime(now.year, now.month, now.day, 9, 30).add(const Duration(days: 1));
      expect(scheduleText(l, t.toUtc().toIso8601String(), null), 'Tomorrow, 9:30 AM');
      expect(scheduleText(l, t.toUtc().toIso8601String(), 'morning'), 'Tomorrow, ${l.slotMorning}');
      final far = DateTime(now.year, now.month, now.day).add(const Duration(days: 9));
      final s = humanDate(l, '${far.year}-${far.month.toString().padLeft(2, '0')}-${far.day.toString().padLeft(2, '0')}')!;
      expect(RegExp(r'^[A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}').hasMatch(s), true, reason: s);
      expect(s.contains('-'), false);
      expect(humanDate(l, null), isNull);
      expect(humanDate(l, 'garbage'), isNull);
      expect(agoText(l, DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String()), '5 min ago');
    });
  });

  group('best match (demo mirror of backend/app/domain/matching.py)', () {
    const good = MatchFacts(verdict: 'fair', rating: 4.8, ratingCount: 40, completedJobs: 60, distanceKm: 1.2, police: true, level: 'master', responseMin: 10);
    const poor = MatchFacts(verdict: 'high', rating: 3.2, ratingCount: 10, completedJobs: 2, distanceKm: 14, police: false, level: 'helper', responseMin: 2000);

    test('score is 0-100 and orders good above poor', () {
      expect(DemoMatching.score(good), greaterThanOrEqualTo(90));
      expect(DemoMatching.score(poor), lessThan(DemoMatching.score(good)));
      expect(DemoMatching.score(poor), inInclusiveRange(0, 100));
    });

    test('reasons are short, ordered, and readable', () {
      expect([for (final r in DemoMatching.reasons(good)) r['code']], ['fair', 'rating', 'distance', 'police']);
      expect(DemoMatching.reasons(poor), isEmpty);
    });

    test('can come today needs: job today, close, free', () {
      expect(DemoMatching.canComeToday(jobIsToday: true, distanceKm: 3, busyToday: false), true);
      expect(DemoMatching.canComeToday(jobIsToday: true, distanceKm: 3, busyToday: true), false);
      expect(DemoMatching.canComeToday(jobIsToday: false, distanceKm: 3, busyToday: false), false);
      expect(DemoMatching.canComeToday(jobIsToday: true, distanceKm: 30, busyToday: false), false);
      expect(DemoMatching.canComeToday(jobIsToday: true, distanceKm: null, busyToday: false), false);
    });

    test('exactly one best match among 2+ pending quotes; the cheaper one wins a tie', () {
      final one = <Json>[{'status': 'pending', 'match_score': 70, 'price_inr': 500}];
      DemoMatching.markBest(one);
      expect(one.first['best_match'], false);
      final rows = <Json>[
        {'status': 'pending', 'match_score': 70, 'price_inr': 600},
        {'status': 'pending', 'match_score': 70, 'price_inr': 500},
        {'status': 'rejected', 'match_score': 99, 'price_inr': 100},
      ];
      DemoMatching.markBest(rows);
      expect([for (final r in rows) r['best_match']], [false, true, false]);
    });

    test('the demo job detail carries the fields', () async {
      SharedPreferences.setMockInitialValues({});
      final api = DemoApi()..language = 'en';
      await api.verifyOtp(_neha, '123456', role: 'customer', lang: 'en');
      final bids = ((await api.customerJob('j2'))['bids'] as List).cast<Json>();
      expect(bids.length, greaterThanOrEqualTo(2));
      for (final b in bids) {
        expect(b['match_score'], isA<int>());
        expect(b['match_reasons'], isA<List>());
        expect(b['can_come_today'], isA<bool>());
        expect(b.containsKey('distance_km'), true);
      }
      expect(bids.where((b) => b['best_match'] == true).length, 1);
    });
  });

  group('job progress', () {
    test('a quoted job is step 1 of 5, a hired and paid job is at the work step', () async {
      SharedPreferences.setMockInitialValues({});
      final api = DemoApi()..language = 'en';
      final l = await L.delegate.load(const Locale('en'));
      await api.verifyOtp(_neha, '123456', role: 'customer', lang: 'en');
      final j2 = await api.customerJob('j2');
      final quoted = jobProgress(l, j2)!;
      expect(quoted.step, 0);
      expect(quoted.title, l.cxPrQuotesReady((j2['bids'] as List).length));
      await api.verifyOtp(_priya, '123456', role: 'customer', lang: 'en');
      final hired = jobProgress(l, await api.customerJob('j3'))!;
      expect(hired.step, inInclusiveRange(1, 3));
      expect(hired.next, isNotEmpty);
      expect(JobProgressInfo.total, 5);
    });
  });
}
