import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';

const languages = [
  ('hi', 'हिन्दी', 'Hindi'), ('bn', 'বাংলা', 'Bengali'), ('te', 'తెలుగు', 'Telugu'),
  ('mr', 'मराठी', 'Marathi'), ('ta', 'தமிழ்', 'Tamil'), ('gu', 'ગુજરાતી', 'Gujarati'),
  ('kn', 'ಕನ್ನಡ', 'Kannada'), ('ml', 'മലയാളം', 'Malayalam'), ('or', 'ଓଡ଼ିଆ', 'Odia'),
  ('pa', 'ਪੰਜਾਬੀ', 'Punjabi'), ('as', 'অসমীয়া', 'Assamese'), ('en', 'English', 'English'),
];

String nativeName(String code) => languages.firstWhere((l) => l.$1 == code, orElse: () => languages.first).$2;

/// S1 — the very first screen. Tapping a tile switches the WHOLE UI to that language instantly,
/// so the user sees immediately that the app speaks their language. 🔊 reads the name aloud for
/// people who recognise their language by sound rather than script.
class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key, required this.state, this.fromSettings = false});
  final AppState state;
  final bool fromSettings;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final selected = state.language;
    return Scaffold(
      appBar: fromSettings ? AppBar() : null,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Row(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: BC.brand, borderRadius: BorderRadius.circular(18)),
                child: const Icon(Icons.translate_rounded, color: Colors.white, size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Before a choice we show Hindi + English together: the two most widely read.
                  Text(selected == null ? 'भाषा चुनें' : l.chooseLanguage, style: Theme.of(context).textTheme.headlineMedium),
                  Text(selected == null ? 'Choose your language' : l.chooseLanguageHint,
                      style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
                ]),
              ),
            ]),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, mainAxisExtent: 96),
              itemCount: languages.length,
              itemBuilder: (ctx, i) {
                final (code, native, english) = languages[i];
                final on = code == selected;
                return Material(
                  color: on ? BC.brandSoft : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(BC.rLg),
                    side: BorderSide(color: on ? BC.brand : BC.line, width: on ? 2.5 : 1.2),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(BC.rLg),
                    onTap: () => state.setLanguage(code),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(children: [
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(native, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, height: 1.3)),
                            if (code != 'en')
                              Text(english, style: const TextStyle(fontSize: 13, color: BC.inkFaint, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                        on
                            ? const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.check_circle_rounded, color: BC.brand, size: 30))
                            : SpeakButton(text: native, lang: code, size: 40),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: FilledButton(
              onPressed: selected == null
                  ? null
                  : () => fromSettings ? context.pop() : context.go(state.loggedIn ? '/' : '/role'),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(selected == null ? 'आगे बढ़ें · Continue' : l.continueBtn),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// "I want work" vs "I need workers". Big pictures first, words second.
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    Widget card(String role, IconData icon, Color color, String title, String sub) => Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: const BorderSide(color: BC.line, width: 1.2)),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: () async {
              await state.setRoleIntent(role);
              if (context.mounted) context.push('/phone');
            },
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(24)),
                  child: Icon(icon, size: 48, color: color),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(sub, style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, size: 32, color: BC.inkFaint),
              ]),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/language')),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 16), child: SpeakButton(text: l.roleQuestion, lang: state.language ?? 'hi')),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), children: [
          Text(l.roleQuestion, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 24),
          card('worker', Icons.construction_rounded, BC.brand, l.roleWorker, l.roleWorkerSub),
          const SizedBox(height: 16),
          card('customer', Icons.home_work_rounded, BC.info, l.roleCustomer, l.roleCustomerSub),
          if (state.isDemo) ...[const SizedBox(height: 28), const Center(child: DemoChip())],
        ]),
      ),
    );
  }
}
