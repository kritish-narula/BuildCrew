import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_state.dart';
import '../../core/config.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../../core/updater.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../onboarding/onboarding.dart';
import 'update_ui.dart';

/// Language, voice help, support (call + WhatsApp), updates, logout — one tap from every
/// profile page, for every role.
List<Widget> settingsTiles(BuildContext context, AppState state) {
  final l = L.of(context);
  Widget tile(IconData icon, Color color, String title, {String? sub, VoidCallback? onTap, Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r), side: const BorderSide(color: BC.line)),
          child: ListTile(
            onTap: onTap,
            minTileHeight: 72,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r)),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 14, color: BC.inkSoft)),
            trailing: trailing ?? const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
          ),
        ),
      );
  final phone = AppConfig.supportPhone;
  return [
    tile(Icons.record_voice_over_rounded, BC.brand, l.askByVoice, sub: l.askByVoiceSub, onTap: () => showVoiceHelp(context, state)),
    tile(Icons.call_rounded, BC.money, l.profileSupport, sub: phone, onTap: () => launchUrl(Uri.parse('tel:$phone'))),
    tile(Icons.chat_rounded, const Color(0xFF128C7E), l.whatsappSupport, sub: l.whatsappSupportSub,
        onTap: () => launchUrl(Uri.parse('https://wa.me/${phone.replaceAll('+', '')}?text=BuildCrew'), mode: LaunchMode.externalApplication)),
    tile(Icons.translate_rounded, BC.info, l.profileLanguage, sub: nativeName(state.language ?? 'hi'), onTap: () => context.push('/language?settings=1')),
    ListenableBuilder(
      listenable: Updater.instance,
      builder: (ctx, _) {
        final up = Updater.instance;
        return tile(Icons.system_update_rounded, BC.info, l.profileUpdates, sub: l.versionLabel(up.currentVersion),
            trailing: up.available != null ? const Icon(Icons.circle, color: BC.danger, size: 12) : null, onTap: () async {
          final info = await up.check(force: true);
          if (!context.mounted) return;
          if (info != null) {
            await showUpdateSheet(context, state.language ?? 'hi');
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.updateUpToDate)));
          }
        });
      },
    ),
    tile(Icons.logout_rounded, BC.closed, l.profileLogout, onTap: state.signOut, trailing: const SizedBox.shrink()),
  ];
}

/// Voice questions ("mera paisa kab aayega?", "kaam kaise milega?") → answer spoken back in
/// the user's language.
Future<void> showVoiceHelp(BuildContext context, AppState state) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _VoiceHelp(state: state),
    );

class _VoiceHelp extends StatefulWidget {
  const _VoiceHelp({required this.state});
  final AppState state;
  @override
  State<_VoiceHelp> createState() => _VoiceHelpState();
}

class _VoiceHelpState extends State<_VoiceHelp> {
  final _stt = SpeechToText();
  String _q = '', _a = '';
  bool _listening = false;

  Future<void> _ask(String q) async {
    setState(() => _q = q);
    try {
      final a = await widget.state.api.voiceQuery(q);
      setState(() => _a = a);
      await Speaker.instance.say(a, widget.state.language ?? 'hi');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _listen() async {
    if (!await _stt.initialize()) return;
    setState(() => _listening = true);
    await _stt.listen(
      localeId: '${widget.state.language ?? 'hi'}_IN',
      listenFor: const Duration(seconds: 8),
      onResult: (r) {
        setState(() => _q = r.recognizedWords);
        if (r.finalResult) {
          setState(() => _listening = false);
          _ask(r.recognizedWords);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.askByVoice, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Center(
            child: GestureDetector(
              onTap: _listen,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: _listening ? 120 : 104,
                height: _listening ? 120 : 104,
                decoration: BoxDecoration(color: _listening ? BC.danger : BC.brand, shape: BoxShape.circle),
                child: const Icon(Icons.mic_rounded, color: Colors.white, size: 52),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_q.isNotEmpty) Text('“$_q”', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontStyle: FontStyle.italic)),
          if (_a.isNotEmpty) ...[
            const SizedBox(height: 12),
            InfoBanner(icon: Icons.volume_up_rounded, color: BC.money, text: _a, onTap: () => Speaker.instance.say(_a, widget.state.language ?? 'hi')),
          ],
          const SizedBox(height: 16),
          Text(l.tryAsking, style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final q in [l.qWhenPaid, l.qHowWork]) ActionChip(label: Text(q, style: const TextStyle(fontSize: 15)), onPressed: () => _ask(q)),
          ]),
        ]),
      ),
    );
  }
}

/// Customer profile (workers have their own richer profile tab).
class ProfileView extends StatelessWidget {
  const ProfileView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final u = state.user;
    final name = (u?.name?.isNotEmpty ?? false) ? u!.name! : '+91 ${u?.phone ?? ''}';
    final initials = name.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w.characters.first).join().toUpperCase();
    return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 32), children: [
      Row(children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: BC.info,
          child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            Row(children: [
              const Icon(Icons.verified_rounded, size: 18, color: BC.money),
              const SizedBox(width: 4),
              Text('${u?.role == 'worker' ? l.role_worker : l.role_customer} · ${l.workerSince}',
                  style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
            ]),
          ]),
        ),
      ]),
      const SizedBox(height: 24),
      ...settingsTiles(context, state),
    ]);
  }
}
