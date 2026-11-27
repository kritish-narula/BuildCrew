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
  ('en_IN', 'Hinglish', 'Hinglish (Roman Hindi)'),
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
            padding: EdgeInsets.fromLTRB(20, fromSettings ? 4 : 24, 20, 8),
            child: Row(children: [
              const IconBadge(Icons.translate_rounded, color: BC.brand, size: 52, solid: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Before a choice we show Hindi + English together: the two most widely read.
                  Text(selected == null ? 'भाषा चुनें' : l.chooseLanguage, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.headlineMedium),
                  Text(selected == null ? 'Choose your language' : l.chooseLanguageHint,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
                ]),
              ),
            ]),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10,
                  // tall enough for big system fonts
                  mainAxisExtent: 80 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.7)),
              itemCount: languages.length,
              itemBuilder: (ctx, i) {
                final (code, native, english) = languages[i];
                final on = code == selected;
                return Material(
                  color: on ? BC.brandSoft : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(BC.rMd),
                    side: BorderSide(color: on ? BC.brand : BC.line, width: on ? 2 : 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => state.setLanguage(code),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                      child: Row(children: [
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(native, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: context.tt.titleLarge!.copyWith(height: 1.4)),
                            if (code != 'en') Text(english, maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.caption.copyWith(color: BC.inkFaint)),
                          ]),
                        ),
                        on
                            ? const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Icon(Icons.check_circle_rounded, color: BC.brand, size: 28))
                            : SpeakButton(text: native, lang: code, size: 36),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: PrimaryButton(
              big: true,
              icon: Icons.arrow_forward_rounded,
              onPressed: selected == null
                  ? null
                  : () => fromSettings ? context.pop() : context.go(state.loggedIn ? '/' : '/role'),
              label: selected == null ? 'आगे बढ़ें · Continue' : l.continueBtn,
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
    Widget card(String role, IconData icon, Color color, String title, String sub) => AppCard(
          radius: BC.rLg,
          padding: const EdgeInsets.all(BC.padLg),
          shadow: true,
          onTap: () async {
            await state.setRoleIntent(role);
            if (context.mounted) context.push('/phone');
          },
          child: Row(children: [
            IconBadge(icon, color: color, size: 68),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.headlineSmall),
                const SizedBox(height: 2),
                Text(sub, maxLines: 3, overflow: TextOverflow.ellipsis, style: BC.subtle),
              ]),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, size: 28, color: BC.inkFaint),
          ]),
        );

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/language')),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 12), child: SpeakButton(text: l.roleQuestion, lang: state.language ?? 'hi')),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), children: [
          Text(l.roleQuestion, style: context.tt.headlineMedium),
          const SizedBox(height: 24),
          card('worker', Icons.construction_rounded, BC.brand, l.roleWorker, l.roleWorkerSub),
          const SizedBox(height: 16),
          card('customer', Icons.home_work_rounded, BC.info, l.roleCustomer, l.roleCustomerSub),
          const SizedBox(height: 16),
          card('contractor', Icons.engineering_rounded, BC.money, l.roleContractor, l.roleContractorSub),
          if (state.isDemo) ...[const SizedBox(height: 28), const Center(child: DemoChip())],
        ]),
      ),
    );
  }
}
