import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_state.dart';
import '../../core/demo_accounts.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../../core/updater.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart' show ReadAloud, tapFeedback;
import '../onboarding/onboarding.dart';
import 'help.dart';
import 'update_ui.dart';

/// Language, voice help, support (call + WhatsApp), updates, logout — one tap from every
/// profile page, for every role.
List<Widget> settingsTiles(BuildContext context, AppState state) {
  final l = L.of(context);
  ReadAloud.ensureLoaded();
  Widget tile(IconData icon, Color color, String title, {String? sub, VoidCallback? onTap, Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              IconBadge(icon, color: color, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium),
                  if (sub != null) Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
                ]),
              ),
              if (trailing != null)
                trailing
              else
                const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
            ]),
          ),
        ),
      );
  Widget section(String t) => Padding(padding: const EdgeInsets.fromLTRB(2, 14, 2, 8), child: Text(t, style: context.tt.titleLarge));
  return [
    section(l.wkSecHelp),
    tile(Icons.support_agent_rounded, BC.money, l.wkHelpTitle, sub: l.wkHelpTitleSub, onTap: () => openHelp(context, state)),
    tile(Icons.record_voice_over_rounded, BC.brand, l.askByVoice, sub: l.askByVoiceSub, onTap: () => showVoiceHelp(context, state)),
    tile(Icons.call_rounded, BC.money, l.profileSupport, sub: kSupportPhone, onTap: () {
      tapFeedback();
      callSupport();
    }),
    tile(Icons.chat_rounded, const Color(0xFF128C7E), l.whatsappSupport, sub: l.whatsappSupportSub, onTap: () {
      tapFeedback();
      whatsappSupport();
    }),
    section(l.wkSecApp),
    ValueListenableBuilder<bool>(
      valueListenable: ReadAloud.enabled,
      builder: (ctx, on, _) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: SwitchListTile(
            value: on,
            onChanged: (v) {
              tapFeedback();
              ReadAloud.set(v);
            },
            secondary: const IconBadge(Icons.volume_up_rounded, color: BC.brand, size: 40),
            title: Text(l.wkReadAloudAuto, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(l.wkReadAloudAutoSub, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    ),
    // HOOK(hinglish): language row. The Hinglish engineer extends the picker behind this route; keep the tile.
    tile(Icons.translate_rounded, BC.info, l.profileLanguage, sub: nativeName(state.language ?? 'hi'), onTap: () => context.push('/language?settings=1')),
    tile(Icons.text_fields_rounded, BC.inkSoft, l.wkTextSize, sub: l.wkTextSizeHint),
    if (state.isDemo) ...[
      Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(color: BC.infoSoft, borderRadius: BorderRadius.circular(BC.rMd)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.switchAccount, style: context.tt.titleMedium!.copyWith(color: BC.info)),
          const SizedBox(height: 2),
          Text(l.switchAccountSub, style: BC.subtle.copyWith(color: BC.info)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (p, trade, name, role) in demoAccounts)
              if (p != state.user?.phone)
                ActionChip(
                  backgroundColor: Colors.white,
                  avatar: Icon(role == 'contractor' ? Icons.engineering_rounded : (role == 'customer' ? Icons.home_work_rounded : TradeStyle.of(trade).icon),
                      color: isDemoCustomerRole(role) ? BC.info : TradeStyle.of(trade).color, size: 18),
                  label: Text('${name.split(' ').first} · ${role == 'contractor' ? l.roleContractor : (role == 'customer' ? l.role_customer : tradeLabel(l, trade))}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: () async {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    await state.switchAccount(p);
                  },
                ),
          ]),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text(l.resetDemo),
                  content: Text(l.resetDemoSub),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: BtnLabel(l.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, BC.btnSm)),
                        child: BtnLabel(l.resetDemo)),
                  ],
                ),
              );
              if (ok == true) await state.resetDemo();
            },
            icon: const Icon(Icons.restart_alt_rounded),
            label: BtnLabel(l.resetDemo),
          ),
        ]),
      ),
    ],
    ListenableBuilder(
      listenable: Updater.instance,
      builder: (ctx, _) {
        final up = Updater.instance;
        return tile(Icons.system_update_rounded, BC.info, l.profileUpdates, sub: '${l.versionLabel(up.currentVersion)} · build ${up.currentCode}',
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
    tile(Icons.logout_rounded, BC.danger, l.profileLogout, onTap: state.signOut, trailing: const SizedBox.shrink()),
  ];
}

/// Voice questions ("mera paisa kab aayega?", "kaam kaise milega?") → answer spoken back in
/// the user's language.
Future<void> showVoiceHelp(BuildContext context, AppState state) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(BC.rLg))),
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

  @override
  void dispose() {
    _stt.cancel(); // release the microphone if the sheet is closed mid-listen
    super.dispose();
  }

  Future<void> _ask(String q) async {
    if (q.trim().isEmpty) return;
    setState(() => _q = q);
    try {
      final a = await widget.state.api.voiceQuery(q);
      if (!mounted) return;
      setState(() => _a = a);
      await Speaker.instance.say(a, widget.state.language ?? 'hi');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _listen() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!await _stt.initialize(onStatus: (s) {
      if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
    })) {
      return;
    }
    if (!mounted) return;
    setState(() => _listening = true);
    await _stt.listen(
      localeId: (widget.state.language ?? 'hi') == 'en_IN' ? 'en_IN' : '${widget.state.language ?? 'hi'}_IN',
      listenFor: const Duration(seconds: 8),
      onResult: (r) {
        if (!mounted) return;
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.askByVoice, style: context.tt.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Center(
            child: GestureDetector(
              onTap: _listen,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: _listening ? 104 : 92,
                height: _listening ? 104 : 92,
                decoration: BoxDecoration(
                  color: _listening ? BC.danger : BC.brand,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: (_listening ? BC.danger : BC.brand).withValues(alpha: 0.3), blurRadius: 20, spreadRadius: 2)],
                ),
                child: const Icon(Icons.mic_rounded, color: Colors.white, size: 46),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_q.isNotEmpty) Text('“$_q”', textAlign: TextAlign.center, style: context.tt.titleMedium!.copyWith(fontStyle: FontStyle.italic, fontWeight: FontWeight.w500)),
          if (_a.isNotEmpty) ...[
            const SizedBox(height: 12),
            InfoBanner(icon: Icons.volume_up_rounded, color: BC.money, text: _a, onTap: () => Speaker.instance.say(_a, widget.state.language ?? 'hi')),
          ],
          const SizedBox(height: 16),
          Text(l.tryAsking, style: context.tt.labelLarge!.copyWith(color: BC.inkSoft)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final q in [l.qWhenPaid, l.qHowWork]) ActionChip(label: Text(q, maxLines: 2, overflow: TextOverflow.ellipsis), onPressed: () => _ask(q)),
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
      AppCard(
        padding: const EdgeInsets.all(BC.padLg),
        child: Row(children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: BC.info,
            child: Text(initials, style: context.tt.headlineSmall!.copyWith(color: Colors.white)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.headlineSmall),
              const SizedBox(height: 2),
              Row(children: [
                const Icon(Icons.verified_rounded, size: 18, color: BC.money),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('${u?.role == 'worker' ? l.role_worker : l.role_customer} · ${l.workerSince}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.subtle),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      ...settingsTiles(context, state),
    ]);
  }
}
