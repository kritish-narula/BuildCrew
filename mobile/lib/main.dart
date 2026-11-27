import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/app_state.dart';
import 'core/notifier.dart';
import 'core/theme.dart';
import 'core/updater.dart';
import 'features/auth/auth_screens.dart';
import 'features/common/notifications.dart';
import 'features/customer/customer_shell.dart';
import 'features/onboarding/onboarding.dart';
import 'features/worker/worker_shell.dart';
import 'l10n/gen/app_localizations.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  final state = await AppState.load();
  await AppNotifier.instance.init(); // single owner of the local-notification plugin (taps -> deep links)
  await Updater.instance.init();
  runApp(BuildCrewApp(state: state));
}

/// Role routing. The redirect is the single gate: no language → S1; not signed in → role/phone/
/// OTP; signed in → home for the role the SERVER assigned (never what the client claims).
GoRouter buildRouter(AppState s) {
  const onboarding = {'/role', '/phone', '/otp'};
  String home() => switch (s.user?.role) { 'worker' => '/worker', 'customer' => '/customer', _ => '/admin' };

  return GoRouter(
    initialLocation: '/',
    refreshListenable: s,
    redirect: (ctx, st) {
      final loc = st.matchedLocation;
      if (s.language == null) return loc == '/language' ? null : '/language';
      if (!s.loggedIn) {
        if (loc == '/language' || onboarding.contains(loc)) return null;
        return '/role';
      }
      if (loc == '/' || onboarding.contains(loc)) return home();
      // Role guard: after "switch account" (demo) the old role's screen must not stay open.
      const roleHomes = {'/worker', '/customer', '/admin'};
      if (roleHomes.contains(loc) && loc != home()) return home();
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
      GoRoute(
          path: '/language',
          builder: (_, st) => LanguageScreen(state: s, fromSettings: st.uri.queryParameters['settings'] == '1')),
      GoRoute(path: '/role', builder: (_, __) => RoleScreen(state: s)),
      GoRoute(path: '/phone', builder: (_, __) => PhoneScreen(state: s)),
      GoRoute(path: '/otp', builder: (_, __) => OtpScreen(state: s)),
      GoRoute(path: '/worker', builder: (_, __) => WorkerShell(state: s)),
      GoRoute(path: '/customer', builder: (_, __) => CustomerShell(state: s)),
      GoRoute(path: '/admin', builder: (_, __) => AdminOnMobile(state: s)),
      // Deep links (notification taps, push `data.link`): pushed on top of the role home, Back returns to it.
      GoRoute(path: '/notifications', builder: (_, __) => NotificationsScreen(state: s)),
      GoRoute(path: '/job/:id', builder: (_, st) => JobDeepLink(state: s, jobId: st.pathParameters['id']!)),
      GoRoute(
          path: '/assignment/:id',
          builder: (_, st) => AssignmentDeepLink(state: s, assignmentId: st.pathParameters['id']!, jobId: st.uri.queryParameters['job'])),
      GoRoute(
          path: '/chat/:jobId/:withUser',
          builder: (_, st) => ChatDeepLink(state: s, jobId: st.pathParameters['jobId']!, withUser: st.pathParameters['withUser']!)),
    ],
  );
}

class BuildCrewApp extends StatefulWidget {
  const BuildCrewApp({super.key, required this.state});
  final AppState state;
  @override
  State<BuildCrewApp> createState() => _BuildCrewAppState();
}

class _BuildCrewAppState extends State<BuildCrewApp> {
  late final GoRouter _router = buildRouter(widget.state);

  @override
  void initState() {
    super.initState();
    // Tapping a system notification opens its screen (also replays a tap that launched the app).
    AppNotifier.instance.onRoute = (route) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.state.loggedIn) _router.push(route);
      });
    };
  }

  @override
  void dispose() {
    AppNotifier.instance.onRoute = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (ctx, _) => MaterialApp.router(
        title: 'BuildCrew',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Design rule #1: the chosen language drives EVERY string, from the first tap.
        locale: Locale(widget.state.language ?? 'hi'),
        supportedLocales: L.supportedLocales,
        localizationsDelegates: const [
          L.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: _router,
        // Android 15 draws apps edge-to-edge: keep every screen (and its bottom buttons) above the
        // phone's back / home / recents bar instead of underneath it.
        builder: (context, child) => ColoredBox(
          color: Colors.white,
          child: SafeArea(top: false, left: false, right: false, child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}

/// Admins sign in on the web panel; the phone app just says so in their language.
class AdminOnMobile extends StatelessWidget {
  const AdminOnMobile({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.desktop_windows_rounded, size: 72, color: BC.brand),
            const SizedBox(height: 16),
            Text(l.adminUseWeb, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            OutlinedButton(onPressed: state.signOut, child: Text(l.profileLogout)),
            const SizedBox(height: 8),
            if (state.isDemo) const DemoChip(),
          ]),
        ),
      ),
    );
  }
}
