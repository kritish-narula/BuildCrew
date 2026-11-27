import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:buildcrew/core/api.dart';
import 'package:buildcrew/core/app_state.dart';
import 'package:buildcrew/core/outbox.dart';
import 'package:buildcrew/core/theme.dart';
import 'package:buildcrew/core/updater.dart';
import 'package:buildcrew/features/auth/auth_screens.dart';
import 'package:buildcrew/features/common/chat.dart';
import 'package:buildcrew/features/common/update_ui.dart';
import 'package:buildcrew/features/customer/customer_job.dart';
import 'package:buildcrew/features/customer/customer_shell.dart';
import 'package:buildcrew/features/customer/payment.dart';
import 'package:buildcrew/features/customer/team_job.dart';
import 'package:buildcrew/features/customer/post_job.dart';
import 'package:buildcrew/features/customer/workers.dart';
import 'package:buildcrew/features/onboarding/onboarding.dart';
import 'package:buildcrew/features/worker/assignment_screen.dart';
import 'package:buildcrew/features/worker/job_detail.dart';
import 'package:buildcrew/features/worker/kyc_screens.dart';
import 'package:buildcrew/features/worker/worker_shell.dart';
import 'package:buildcrew/l10n/gen/app_localizations.dart';
import 'package:buildcrew/widgets/media.dart';
import 'package:buildcrew/widgets/trust_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screenshot + layout-overflow test for the key screens.
///
///  * Every screen is pumped at phone sizes (360x800 @2x and 320x640 @3x) in English and Hindi
///    with the REAL Mukta font and Material icons so the PNGs are readable.
///  * PNGs go to `test/screens_out/<screen>_<locale>_<width>.png` (CI publishes them).
///  * A failure on one screen never hides the others: errors are collected per screen, and the
///    test fails at the end with the full list. RenderFlex overflows always fail the test.
///
/// Personas: ONE AppState/DemoApi (the demo "database" is cached per instance) and the signed-in
/// user is switched with `AppState.switchAccount` exactly like the in-app demo helper.
const _anil = '9100000002'; // contractor: team sites t1 (running, 5/7 filled) and t2 (hiring)
const _priya = '9100000001'; // customer: open job j1, assigned j3 (paid), bidding j6
const _neha = '9100000003'; // customer: j2 with 3 quotes (one below min wage), j5 awaiting rating
const _ramesh = '9200000001'; // mason: in-progress job a4, earnings history
const _harpreet = '9200000007'; // carpenter hired on j3
const _selvam = '9200000009'; // painter, completed job a5
const _imran = '9200000003'; // plumber: same-day payout today, police-verified, hired again by Priya
const _gopal = '9200000004'; // plumber: no police request yet (verification step)

late AppState state;
final Map<String, String> _secure = {};

class _Screen {
  _Screen(this.name, this.phone, this.build, {this.prepare, this.act, this.scrollBottom = false, this.afterScroll, this.cleanup});
  final String name;
  final String? phone;
  final Widget Function() build;
  final Future<void> Function()? prepare; // real-time data set-up (runs outside fake time)
  final Future<void> Function(WidgetTester)? act; // taps before the first capture
  final bool scrollBottom; // also capture `<name>_bottom` after scrolling to the end
  final Future<void> Function(WidgetTester)? afterScroll;
  final void Function()? cleanup;
}

// ------------------------------------------------------------------ environment
void _installMocks() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return _secure[key];
      case 'write':
        _secure[key!] = args['value'] as String;
        return null;
      case 'delete':
        _secure.remove(key);
        return null;
      case 'containsKey':
        return _secure.containsKey(key);
      case 'readAll':
        return Map<String, String>.of(_secure);
      case 'deleteAll':
        _secure.clear();
        return null;
    }
    return null;
  });
  // Plugins the screens touch only on interaction, but their constructors may ping the channel.
  for (final name in const [
    'com.ryanheise.just_audio.methods',
    'com.ryanheise.audio_session',
    'flutter_tts',
    'com.llfbandit.record/messages',
    'plugin.csdcorp.com/speech_to_text',
    'flutter.baseflow.com/geolocator',
    'dev.fluttercommunity.plus/package_info',
    'plugins.flutter.io/url_launcher',
    'buildcrew/updater',
  ]) {
    m.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
  }
}

String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  final exe = Platform.resolvedExecutable; // <root>/bin/cache/artifacts/engine/<os>/flutter_tester
  final i = exe.indexOf('/bin/cache/');
  return i > 0 ? exe.substring(0, i) : null;
}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final bytes = f.readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    any = true;
  }
  if (any) await loader.load();
}

Future<void> _loadFonts() async {
  await _loadFont('Mukta', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) 'assets/fonts/Mukta-$w.ttf',
  ]);
  final root = _flutterRoot();
  if (root == null) {
    debugPrint('screens_test: FLUTTER_ROOT unknown, icons will render as boxes');
    return;
  }
  await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}

// ------------------------------------------------------------------ harness
Widget _harness(Key key, String lang, Widget home) => RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: Locale(lang),
        supportedLocales: L.supportedLocales,
        localizationsDelegates: const [
          L.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );

Future<T?> _real<T>(WidgetTester t, Future<T> Function() f) => t.runAsync<T>(f);

Future<void> _pumpFor(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 250; i++) {
    await t.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _capture(WidgetTester t, GlobalKey key, String path) async {
  await t.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsBytes(data!.buffer.asUint8List());
  });
}

Finder _navIcon(IconData icon) => find.descendant(of: find.byType(NavigationBar), matching: find.byIcon(icon));
Finder _mainScrollable() => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.tap(f.first, warnIfMissed: false);
  await _pumpFor(t, 1500);
}

// ------------------------------------------------------------------ error collection
class _Report {
  final overflows = <String, Set<String>>{};
  final others = <String, Set<String>>{};
  final failed = <String, String>{};
  final ignored = <String, int>{};
  var current = '-';

  static const _envLimits = [
    'MissingPluginException', 'NetworkImageLoadException', 'HttpException', 'SocketException', 'Failed host lookup',
    'HTTP request failed', 'PlatformException', 'ClientException',
  ];

  void add(FlutterErrorDetails d) {
    final text = d.exceptionAsString();
    final deep = d.toString();
    if (_envLimits.any(text.contains)) {
      ignored[current] = (ignored[current] ?? 0) + 1;
      return;
    }
    final widget = RegExp(r'error-causing widget was:\s*\n\s*(.*)').firstMatch(deep)?.group(1) ?? '';
    final loc = RegExp(r'(lib/[\w/]+\.dart:\d+)').firstMatch(deep)?.group(1) ?? '';
    final line = text.split('\n').first;
    final entry = '$line ${widget.isEmpty ? '' : '[$widget]'} ${loc.isEmpty ? '' : '($loc)'}'.trim();
    final bucket = text.contains('overflowed') ? overflows : others;
    bucket.putIfAbsent(current, () => <String>{}).add(entry);
  }

  bool get hasFailures => overflows.isNotEmpty || others.isNotEmpty || failed.isNotEmpty;

  String render(String title) {
    final b = StringBuffer('\n===== $title =====\n');
    void section(String head, Map<String, Iterable<String>> m) {
      if (m.isEmpty) return;
      b.writeln('$head (${m.length} screens)');
      m.forEach((k, v) {
        for (final e in v) {
          b.writeln('  - $k: $e');
        }
      });
    }

    section('RENDER OVERFLOW', overflows);
    section('OTHER FLUTTER ERRORS', others);
    section('SCREEN COULD NOT BE CAPTURED', {for (final e in failed.entries) e.key: [e.value]});
    if (ignored.isNotEmpty) b.writeln('(ignored ${ignored.values.fold<int>(0, (a, c) => a + c)} network/plugin errors in test environment)');
    return b.toString();
  }
}

Future<void> _runScreens(WidgetTester t, List<_Screen> screens, String lang, double w, double h, double dpr) async {
  t.view.physicalSize = Size(w * dpr, h * dpr);
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  _installMocks();

  final report = _Report();
  final previous = FlutterError.onError;
  FlutterError.onError = report.add;
  try {
    await _real(t, () => state.setLanguage(lang));
    for (final s in screens) {
      report.current = s.name;
      final key = GlobalKey();
      final file = 'test/screens_out/${s.name}_${lang}_${w.toInt()}.png';
      try {
        if (s.phone != null && state.user?.phone != s.phone) await _real(t, () => state.switchAccount(s.phone!));
        if (s.prepare != null) await _real(t, s.prepare!);
        await t.pumpWidget(_harness(key, lang, s.build()));
        await _pumpFor(t, 3000);
        if (s.act != null) {
          await s.act!(t);
          await _pumpFor(t, 1000);
        }
        await _capture(t, key, file);
        if (s.scrollBottom) {
          final sc = _mainScrollable();
          if (sc.evaluate().isNotEmpty) {
            await t.drag(sc.first, const Offset(0, -5000), warnIfMissed: false);
            await _pumpFor(t, 500);
            if (s.afterScroll != null) {
              await s.afterScroll!(t);
              await _pumpFor(t, 500);
            }
            await _capture(t, key, file.replaceFirst('.png', '_bottom.png'));
          }
        }
      } catch (e, st) {
        report.failed[s.name] = '$e\n${st.toString().split('\n').take(3).join('\n')}';
      } finally {
        s.cleanup?.call();
        // dispose the screen so its polling timers die, then let in-flight DemoApi lags finish
        try {
          await t.pumpWidget(const SizedBox());
          await _pumpFor(t, 3000);
        } catch (_) {}
      }
    }
  } finally {
    FlutterError.onError = previous;
  }
  if (report.hasFailures) fail(report.render('${lang.toUpperCase()} ${w.toInt()}x${h.toInt()}'));
}

// ------------------------------------------------------------------ screen catalogue
Json? _rateJob, _ratePrevAssign;
List<Json> _payments = [];

Future<void> _asSend(String phone, String jobId, String to, String body) async {
  await state.switchAccount(phone);
  await state.api.sendChat(jobId, to, body);
}

List<_Screen> _coreScreens() => [
      _Screen('onboarding_language', null, () => LanguageScreen(state: state)),
      _Screen('onboarding_role', null, () => RoleScreen(state: state)),
      _Screen('login_phone', null, () => PhoneScreen(state: state)),
      _Screen('login_otp', null, () {
        state.pendingPhone = '9876543210';
        return OtpScreen(state: state);
      }),
      // ---- worker (Ramesh, mason)
      _Screen('worker_jobs', _ramesh, () => WorkerShell(state: state)),
      _Screen('worker_bids', _ramesh, () => WorkerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.receipt_long_outlined))),
      _Screen('worker_earnings', _ramesh, () => WorkerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.currency_rupee_rounded))),
      _Screen('worker_profile', _ramesh, () => WorkerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.person_outline_rounded))),
      _Screen('worker_job_detail', _ramesh, () => JobDetailScreen(state: state, jobId: 'j1'),
          scrollBottom: true, afterScroll: (t) async {
        final f = find.byType(TextField);
        if (f.evaluate().isNotEmpty) await t.enterText(f.first, '9000');
      }),
      _Screen('worker_my_work', _ramesh, () => AssignmentScreen(state: state, assignmentId: 'a4'), scrollBottom: true),
      _Screen('worker_my_work_completed', _selvam, () => AssignmentScreen(state: state, assignmentId: 'a5'), scrollBottom: true),
      // ---- customer (Priya)
      _Screen('customer_home', _priya, () => CustomerShell(state: state)),
      _Screen('customer_bookings_open', _priya, () => CustomerShell(state: state), act: (t) async {
        await _tap(t, _navIcon(Icons.assignment_outlined));
      }),
      _Screen('customer_bookings_ongoing', _priya, () => CustomerShell(state: state), act: (t) async {
        await _tap(t, _navIcon(Icons.assignment_outlined));
        await _tap(t, find.byType(Tab).at(1));
      }),
      _Screen('customer_bookings_past', _priya, () => CustomerShell(state: state), act: (t) async {
        await _tap(t, _navIcon(Icons.assignment_outlined));
        await _tap(t, find.byType(Tab).at(2));
      }),
      _Screen('customer_profile', _priya, () => CustomerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.person_outline_rounded)), scrollBottom: true),
      _Screen('customer_job_bids', _neha, () => CustomerJobScreen(state: state, jobId: 'j2'), scrollBottom: true),
      _Screen('customer_job_tracking', _priya, () => CustomerJobScreen(state: state, jobId: 'j3'), scrollBottom: true, prepare: () async {
        await state.switchAccount(_harpreet);
        final a = (await state.api.assignments()).firstWhere((x) => (x['job'] as Json)['id'] == 'j3');
        await state.api.startJourney(a['id'] as String, null, null); // restart the demo journey: marker ~2.8 km away
        await state.switchAccount(_priya);
      }),
      _Screen('payment', _priya, () => PaymentScreen(state: state, jobId: 'j6', workerName: 'Imran Shaikh', price: 3500, fee: 30), scrollBottom: true),
      _Screen('rate_worker', _neha, () => RateWorkerScreen(state: state, job: _rateJob!, a: _ratePrevAssign!), scrollBottom: true, prepare: () async {
        _rateJob = await state.api.customerJob('j5');
        _ratePrevAssign = _rateJob!['assignment'] as Json;
      }),
      _Screen('payment_success', _priya, () => PaymentSuccessScreen(payment: _payments.first, workerName: 'Harpreet Singh'), prepare: () async {
        _payments = await state.api.payments();
      }),
      _Screen('receipt', _priya, () => ReceiptScreen(payment: _payments.first, workerName: 'Harpreet Singh', trades: const ['carpenter']),
          scrollBottom: true, prepare: () async {
        _payments = await state.api.payments();
      }),
      _Screen('chat_customer', _priya, () => ChatScreen(state: state, jobId: 'j3', withUser: 'w7', title: 'Harpreet Singh')),
      _Screen('chat_worker', _harpreet, () => ChatScreen(state: state, jobId: 'j3', withUser: 'c1', title: 'Priya Sharma')),
      // a fresh unread message every run, so the inbox always shows the badge
      _Screen('messages_inbox_customer', _priya, () => ChatInboxScreen(state: state), prepare: () async {
        await _asSend(_harpreet, 'j3', 'c1', 'Kuch aur chahiye to bata dena.');
        await state.switchAccount(_priya);
      }),
      _Screen('messages_inbox_worker', _harpreet, () => ChatInboxScreen(state: state), prepare: () async {
        await _asSend(_priya, 'j3', 'w7', 'Theek hai, dhanyavaad.');
        await state.switchAccount(_harpreet);
      }),
    ];

String? _refixJobId;
Json? _rebook;

/// Restarts the demo journey of Harpreet's hire on j3 so the customer can share the live trip / sees the start code.
Future<void> _restartJ3Journey() async {
  await state.switchAccount(_harpreet);
  final a = (await state.api.assignments()).firstWhere((x) => (x['job'] as Json)['id'] == 'j3');
  await state.api.startJourney(a['id'] as String, null, null);
  await state.switchAccount(_priya);
}

List<_Screen> _trustScreens() => [
      // ---- trust & worker features
      _Screen('customer_start_code', _priya, () => CustomerJobScreen(state: state, jobId: 'j3'), scrollBottom: true, prepare: _restartJ3Journey),
      _Screen('worker_checkin_code', _harpreet, () => Builder(builder: (ctx) => Scaffold(body: Center(child: FilledButton(
          onPressed: () => showStartCodeSheet(ctx, submit: (c) async {}), child: const Text('code'))))),
          act: (t) => _tap(t, find.byType(FilledButton))),
      _Screen('customer_share_trip', _priya, () => Builder(builder: (ctx) => Scaffold(body: Center(child: FilledButton(
          onPressed: () => showShareTripSheet(ctx, state.api, 'j3'), child: const Text('share'))))),
          prepare: _restartJ3Journey, act: (t) => _tap(t, find.byType(FilledButton))),
      _Screen('worker_police_verification', _gopal, () => WorkerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.person_outline_rounded)), scrollBottom: true),
      _Screen('customer_warranty', _priya, () => CustomerJobScreen(state: state, jobId: 'jw'), scrollBottom: true),
      _Screen('customer_refix_job', _priya, () => CustomerJobScreen(state: state, jobId: _refixJobId ?? 'jw'), scrollBottom: true, prepare: () async {
        try {
          await state.api.requestRefix('jw', reason: 'Tap joint is dripping again', photos: const ['photos/leak_1.jpg']);
        } catch (_) {} // already asked in an earlier language run
        final rows = await state.api.customerJobs();
        _refixJobId = rows.cast<Json>().firstWhere((j) => j['refix'] == true, orElse: () => {'id': 'jw'})['id'] as String;
      }),
      _Screen('worker_earnings_paid_today', _imran, () => WorkerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.currency_rupee_rounded)), scrollBottom: true),
      _Screen('worker_level_card', _ramesh, () => WorkerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.person_outline_rounded)), scrollBottom: true),
      _Screen('customer_hire_again_post_job', _priya, () => PostJobScreen(state: state, prefill: _rebook), scrollBottom: true, prepare: () async {
        _rebook = await state.api.rebookDraft(workerId: 'w3');
      }),
      _Screen('worker_direct_request', _ramesh, () => WorkerShell(state: state)),
    ];

List<_Screen> _extraScreens(String lang) => [
      _Screen('update_sheet', _priya, () => Builder(builder: (ctx) => Scaffold(body: Center(child: FilledButton(onPressed: () => showUpdateSheet(ctx, lang), child: const Text('update'))))),
          prepare: () async {
        Updater.instance.available = UpdateInfo(
          versionName: '0.5.0',
          versionCode: 501,
          url: 'https://example.invalid/BuildCrew.apk',
          sha256: 'ab',
          sizeBytes: 21 * 1024 * 1024,
          notes: {'en': '- Faster job feed\n- Chat fixes', 'hi': '- तेज़ जॉब फ़ीड\n- चैट में सुधार'},
          required: false,
        );
      }, act: (t) => _tap(t, find.byType(FilledButton)), cleanup: () => Updater.instance.available = null),
      _Screen('customer_post_job', _priya, () => PostJobScreen(state: state), scrollBottom: true),
      _Screen('customer_browse_workers', _priya, () => BrowseWorkersScreen(state: state)),
      _Screen('customer_worker_profile', _priya, () => WorkerProfileScreen(state: state, workerId: 'w5'), scrollBottom: true),
      _Screen('customer_payments', _priya, () => PaymentsScreen(state: state)),
      _Screen('customer_messages_tab', _priya, () => CustomerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.chat_bubble_outline_rounded))),
      _Screen('worker_labour_card', _ramesh, () => LabourCardScreen(state: state), scrollBottom: true),
      _Screen('worker_kyc_level1', _selvam, () => KycLevel1Screen(state: state), scrollBottom: true),
      // ---- contractor team hiring, scheduling and post-job rules
      _Screen('contractor_home', _anil, () => CustomerShell(state: state), scrollBottom: true),
      _Screen('contractor_team_tab', _anil, () => CustomerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.groups_outlined)), scrollBottom: true),
      _Screen('contractor_team_post', _anil, () => PostJobScreen(state: state, team: true), act: (t) => _tap(t, find.byType(InkWell))),
      _Screen('contractor_team_roster', _anil, () => TeamJobScreen(state: state, jobId: 't1'), scrollBottom: true),
      _Screen('contractor_team_hiring', _anil, () => TeamJobScreen(state: state, jobId: 't2'), scrollBottom: true),
      _Screen('worker_feed_team_job', _selvam, () => WorkerShell(state: state), scrollBottom: true),
      _Screen('customer_scheduled_cards', _priya, () => CustomerShell(state: state), act: (t) => _tap(t, _navIcon(Icons.assignment_outlined))),
      _Screen('customer_post_job_rules', _priya, () => PostJobScreen(state: state), act: (t) async {
        await _tap(t, find.byType(InkWell)); // pick the first trade
        await _tap(t, find.byType(FilledButton)); // Continue -> work step
        final f = find.byType(TextField);
        if (f.evaluate().isNotEmpty) await t.enterText(f.first, 'Kitchen tap is leaking badly'); // short: counter + reason
        await _pumpFor(t, 600);
      }, scrollBottom: true),
      // ---- customer UX: starter text from a template, the "See an example" sheet, and a job that waits for the rating
      _Screen('customer_post_example', _priya, () => PostJobScreen(state: state), act: (t) async {
        await _tap(t, find.byType(InkWell)); // first common job -> describe step with the starter text
        await _tap(t, find.byKey(const ValueKey('seeExample')));
      }),
      _Screen('customer_job_rating_due', _neha, () => CustomerJobScreen(state: state, jobId: 'j5'), scrollBottom: true),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    AppImage.allowNetwork = false;
    SharedPreferences.setMockInitialValues({});
    _installMocks();
    await _loadFonts();
    state = await AppState.load(); // DemoApi-backed (no API_BASE_URL defined in tests)
    // Outbox owns a never-cancelled periodic timer: start it here, outside any fake-async test zone.
    await Outbox.instance.init(state.api);
    // A short conversation on job j3 (Priya <-> Harpreet): customer 2 msgs, worker 1 reply.
    await _asSend(_priya, 'j3', 'w7', 'Namaste, kal subah aa sakte ho?');
    await state.api.sendChat('j3', 'w7', 'Address Aundh, Pune. Pehle photo dekh lena.');
    await _asSend(_harpreet, 'j3', 'c1', 'Ji, main subah 9 baje aa jaunga. Naya hinge aur handle saath laaunga.');
  });

  setUp(_installMocks);

  const sizes = [(360.0, 800.0, 2.0), (320.0, 640.0, 3.0)];
  for (final lang in const ['en', 'hi']) {
    for (final (w, h, dpr) in sizes) {
      testWidgets('key screens: $lang ${w.toInt()}x${h.toInt()}', (t) async {
        await _runScreens(t, _coreScreens(), lang, w, h, dpr);
      }, timeout: const Timeout(Duration(minutes: 8)));
    }
    testWidgets('extra screens: $lang 360x800', (t) async {
      await _runScreens(t, _extraScreens(lang), lang, 360, 800, 2);
    }, timeout: const Timeout(Duration(minutes: 5)));
    for (final (w, h, dpr) in sizes) {
      testWidgets('trust & worker screens: $lang ${w.toInt()}x${h.toInt()}', (t) async {
        await _runScreens(t, _trustScreens(), lang, w, h, dpr);
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }
}
