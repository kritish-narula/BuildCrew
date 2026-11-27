import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import 'completion_ui.dart' show PhotoPickerRow;

/// BuildCrew support line (calls + WhatsApp). Override at build time with --dart-define=SUPPORT_PHONE=+91...
const kSupportPhone = String.fromEnvironment('SUPPORT_PHONE', defaultValue: '+91 79734 93558');

String get _supportDigits => kSupportPhone.replaceAll(RegExp(r'[^0-9]'), '');

Future<void> callSupport() => launchUrl(Uri.parse('tel:+$_supportDigits'));

Future<void> whatsappSupport([String text = 'BuildCrew']) =>
    launchUrl(Uri.parse('https://wa.me/$_supportDigits?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);

/// Opens Help & Support (both roles). [problem] jumps straight to the report form (used from dispute screens).
Future<void> openHelp(BuildContext context, AppState state, {bool problem = false}) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => HelpScreen(state: state, startWithReport: problem)));

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, required this.state, this.startWithReport = false});
  final AppState state;
  final bool startWithReport;
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.startWithReport) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReportProblemScreen(state: widget.state)));
      });
    }
  }

  bool get _worker => widget.state.user?.role == 'worker';

  List<(String, String)> _faq(L l) => _worker
      ? [
          (l.wkFaqW1Q, l.wkFaqW1A), (l.wkFaqW2Q, l.wkFaqW2A), (l.wkFaqW3Q, l.wkFaqW3A), (l.wkFaqW4Q, l.wkFaqW4A), (l.wkFaqW5Q, l.wkFaqW5A),
          (l.wkFaqW6Q, l.wkFaqW6A), (l.wkFaqW7Q, l.wkFaqW7A), (l.wkFaqW8Q, l.wkFaqW8A), (l.wkFaqW9Q, l.wkFaqW9A), (l.wkFaqW10Q, l.wkFaqW10A),
        ]
      : [
          (l.wkFaqC1Q, l.wkFaqC1A), (l.wkFaqC2Q, l.wkFaqC2A), (l.wkFaqC3Q, l.wkFaqC3A), (l.wkFaqC4Q, l.wkFaqC4A), (l.wkFaqC5Q, l.wkFaqC5A),
          (l.wkFaqC6Q, l.wkFaqC6A), (l.wkFaqC7Q, l.wkFaqC7A), (l.wkFaqC8Q, l.wkFaqC8A), (l.wkFaqC9Q, l.wkFaqC9A), (l.wkFaqC10Q, l.wkFaqC10A),
        ];

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final lang = widget.state.language ?? 'hi';
    return Scaffold(
      appBar: AppBar(title: Text(l.wkHelpTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          Row(children: [
            Expanded(child: Text(l.wkHelpHours, style: BC.subtle)),
            ReadButton(text: l.wkHelpHours, lang: lang),
          ]),
          const SizedBox(height: 8),
          PrimaryButton(
              big: true,
              color: BC.money,
              icon: Icons.call_rounded,
              label: l.profileSupport,
              onPressed: () {
                tapFeedback();
                callSupport();
              }),
          const SizedBox(height: 10),
          PrimaryButton(
              big: true,
              color: const Color(0xFF128C7E),
              icon: Icons.chat_rounded,
              label: l.whatsappSupport,
              onPressed: () {
                tapFeedback();
                whatsappSupport();
              }),
          const SizedBox(height: 10),
          SecondaryButton(
              icon: Icons.report_problem_rounded,
              label: l.wkHelpReport,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReportProblemScreen(state: widget.state)))),
          const SizedBox(height: 20),
          SectionHeader(l.wkHelpFaq),
          for (final (q, a) in _faq(l))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                padding: EdgeInsets.zero,
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                    childrenPadding: const EdgeInsets.fromLTRB(14, 0, 6, 12),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    title: Text(q, style: context.tt.titleMedium),
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Text(a, style: context.tt.bodyLarge)),
                        ReadButton(text: '$q. $a', lang: lang),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          SectionHeader(l.wkSafetyTitle),
          for (final t in [l.wkSafety1, l.wkSafety2, l.wkSafety3, l.wkSafety4])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InfoBanner(icon: Icons.health_and_safety_rounded, color: BC.info, text: t),
            ),
          const SizedBox(height: 12),
          _legal(context, Icons.description_outlined, l.wkTerms),
          _legal(context, Icons.privacy_tip_outlined, l.wkPrivacy),
        ]),
      ),
    );
  }

  // Placeholder pages until the legal text is published.
  Widget _legal(BuildContext context, IconData icon, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AppCard(
          onTap: () => showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(title),
              content: Text(L.of(context).wkLegalSoon),
              actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L.of(context).close))],
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              Icon(icon, color: BC.inkSoft),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: context.tt.titleMedium)),
              const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
            ]),
          ),
        ),
      );
}

/// Category + text + optional photo. Uses the support API; falls back to a prefilled WhatsApp message.
class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, required this.state});
  final AppState state;
  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _text = TextEditingController();
  String _cat = 'payment';
  List<String> _photos = [];
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final l = L.of(context);
    final body = _text.text.trim();
    if (body.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.wkReportNeedText)));
      return;
    }
    tapFeedback();
    setState(() => _busy = true);
    final photoNote = _photos.isEmpty ? '' : ' [${_photos.length} photo]';
    try {
      await widget.state.api.supportTicket('[$_cat]', '$body$photoNote');
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: BC.money, size: 56),
          title: Text(l.wkReportSent, textAlign: TextAlign.center),
          actions: [PrimaryButton(onPressed: () => Navigator.pop(c), label: l.ok)],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // No ticket service reachable: let the person send the same words on WhatsApp.
      await whatsappSupport('[$_cat] $body$photoNote');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final cats = [
      ('payment', Icons.payments_rounded, l.wkCatPayment),
      ('job', Icons.handyman_rounded, l.wkCatJob),
      ('app', Icons.phone_android_rounded, l.wkCatApp),
      ('safety', Icons.health_and_safety_rounded, l.wkCatSafety),
      ('other', Icons.more_horiz_rounded, l.wkCatOther),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l.wkHelpReport, maxLines: 1, overflow: TextOverflow.ellipsis)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: PrimaryButton(big: true, busy: _busy, icon: Icons.send_rounded, label: l.wkReportSend, onPressed: _send),
        ),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
        Text(l.wkReportSub, style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
        const SizedBox(height: 14),
        Text(l.wkReportCategory, style: context.tt.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (code, icon, label) in cats)
            ChoiceChip(
              avatar: Icon(icon, size: 20),
              label: Text(label),
              selected: _cat == code,
              onSelected: (_) => setState(() => _cat = code),
            ),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          minLines: 4,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: l.wkReportHint),
        ),
        const SizedBox(height: 14),
        Text(l.wkReportPhoto, style: context.tt.titleMedium),
        const SizedBox(height: 8),
        PhotoPickerRow(photos: _photos, max: 1, onChanged: (p) => setState(() => _photos = p)),
      ]),
    );
  }
}
