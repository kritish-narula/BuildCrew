import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import 'worker_shell.dart' show badgeLabel;

/// Progressive KYC (design rule #3): Level 0 = phone only, can browse/listen/bid.
/// Level 1 (name + selfie + UPI) is asked only when there's money to send.
/// Level 2 (Aadhaar/PAN photo) only as earnings approach the configured cap.
class KycNudge extends StatelessWidget {
  const KycNudge({super.key, required this.state, required this.onDone});
  final AppState state;
  final Future<void> Function() onDone;
  @override
  Widget build(BuildContext context) => InfoBanner(
        icon: Icons.celebration_rounded,
        color: BC.money,
        text: L.of(context).kycL1Nudge,
        action: L.of(context).addNow,
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel1Screen(state: state)));
          await onDone();
        },
      );
}

class KycStatusCard extends StatelessWidget {
  const KycStatusCard({super.key, required this.state, required this.kyc, required this.onChanged});
  final AppState state;
  final Json kyc;
  final Future<void> Function() onChanged;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final level = kyc['level'] as int;
    Widget step(int n, String title, bool done, {VoidCallback? onTap, String? status}) => InkWell(
          onTap: done ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: BC.pad, vertical: 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: done ? BC.money : BC.closedSoft,
                  child: done
                      ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                      : Text('$n', style: context.tt.labelLarge),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium),
                    if (status != null) Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
                  ]),
                ),
                if (!done && onTap != null) const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
              ]),
            ),
          ),
        );
    final doc = kyc['doc_status'] as String;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(BC.pad, 8, BC.pad, 4),
          child: Text(l.verification, style: context.tt.titleLarge),
        ),
        step(0, l.kycPhone, true),
        step(1, l.kycL1Title, level >= 1, onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel1Screen(state: state)));
          await onChanged();
        }),
        step(2, l.kycL2Title, level >= 2,
            status: doc == 'pending' ? l.kycUnderReview : (doc == 'rejected' ? l.kycRejected : l.kycL2When),
            onTap: doc == 'pending'
                ? null
                : () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel2Screen(state: state)));
                    await onChanged();
                  }),
      ]),
    );
  }
}

class KycLevel1Screen extends StatefulWidget {
  const KycLevel1Screen({super.key, required this.state});
  final AppState state;
  @override
  State<KycLevel1Screen> createState() => _KycLevel1ScreenState();
}

class _KycLevel1ScreenState extends State<KycLevel1Screen> {
  late final _name = TextEditingController(text: widget.state.user?.name ?? '');
  final _upi = TextEditingController();
  String? _selfie;
  final Set<String> _trades = {};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _upi.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().length >= 2 && RegExp(r'^[a-zA-Z0-9.\-_]{2,64}@[a-zA-Z]{2,32}$').hasMatch(_upi.text.trim()) && _selfie != null;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final key = (await widget.state.api.upload('selfie', _selfie!))['key'] as String;
      await widget.state.api.kycLevel1(name: _name.text.trim(), upi: _upi.text.trim(), selfieKey: key, trades: _trades.isEmpty ? null : _trades.toList());
      await widget.state.updateUser(name: _name.text.trim(), kycLevel: 1);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.kycL1Title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        Text(l.kycL1Why, style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
        const SizedBox(height: 20),
        Center(
          child: GestureDetector(
            onTap: () async {
              final p = await pickPhoto(context, cameraOnly: true);
              if (p != null) setState(() => _selfie = p);
            },
            child: Column(children: [
              CircleAvatar(
                radius: 64,
                backgroundColor: BC.brandSoft,
                child: _selfie == null
                    ? const Icon(Icons.add_a_photo_rounded, size: 48, color: BC.brandDark)
                    : ClipOval(child: AppImage(_selfie, width: 128, height: 128)),
              ),
              const SizedBox(height: 8),
              Text(l.takeSelfie, style: context.tt.titleMedium!.copyWith(color: BC.brandDark)),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        TextField(controller: _name, textCapitalization: TextCapitalization.words, style: context.tt.titleLarge,
            decoration: InputDecoration(labelText: l.yourName, prefixIcon: const Icon(Icons.person_rounded)), onChanged: (_) => setState(() {})),
        const SizedBox(height: 14),
        TextField(controller: _upi, keyboardType: TextInputType.emailAddress, autocorrect: false, style: context.tt.titleLarge,
            decoration: InputDecoration(labelText: l.upiId, hintText: 'name@okaxis', prefixIcon: const Icon(Icons.account_balance_wallet_rounded)),
            onChanged: (_) => setState(() {})),
        const SizedBox(height: 20),
        Text(l.yourSkills, style: context.tt.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in const ['mason', 'plumber', 'electrician', 'carpenter', 'painter', 'helper'])
            FilterChip(
              selected: _trades.contains(t),
              onSelected: (v) => setState(() => v ? _trades.add(t) : _trades.remove(t)),
              avatar: Icon(TradeStyle.of(t).icon, color: TradeStyle.of(t).color),
              label: Text(tradeLabel(l, t), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ]),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.lock_rounded, color: BC.info, text: l.kycPrivacy),
        const SizedBox(height: 20),
        PrimaryButton(big: true, busy: _busy, onPressed: _valid ? _save : null, label: l.save),
      ]),
    );
  }
}

class KycLevel2Screen extends StatefulWidget {
  const KycLevel2Screen({super.key, required this.state});
  final AppState state;
  @override
  State<KycLevel2Screen> createState() => _KycLevel2ScreenState();
}

class _KycLevel2ScreenState extends State<KycLevel2Screen> {
  String _type = 'aadhaar';
  String? _photo;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.kycL2Title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        Text(l.kycL2Why, style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
        const SizedBox(height: 16),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'aadhaar', label: Text(l.aadhaar, maxLines: 1, overflow: TextOverflow.ellipsis), icon: const Icon(Icons.fingerprint_rounded)),
            ButtonSegment(value: 'pan', label: Text(l.pan, maxLines: 1, overflow: TextOverflow.ellipsis), icon: const Icon(Icons.credit_card_rounded)),
          ],
          selected: {_type},
          onSelectionChanged: (s) => setState(() => _type = s.first),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () async {
            final p = await pickPhoto(context);
            if (p != null) setState(() => _photo = p);
          },
          child: Container(
            height: 200,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.rMd), border: Border.all(color: BC.line, width: 1.5)),
            clipBehavior: Clip.antiAlias,
            child: _photo == null
                ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.document_scanner_rounded, size: 56, color: BC.brand),
                    const SizedBox(height: 8),
                    Text(l.photoOfCard, style: context.tt.titleMedium),
                  ])
                : AppImage(_photo, width: double.infinity),
          ),
        ),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.lock_rounded, color: BC.info, text: l.kycL2Privacy),
        const SizedBox(height: 20),
        PrimaryButton(
          big: true,
          busy: _busy,
          label: l.submitForReview,
          onPressed: _photo == null
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final key = (await widget.state.api.upload('kyc', _photo!))['key'] as String;
                    await widget.state.api.kycLevel2(_type, key);
                    if (mounted) Navigator.pop(context);
                  } catch (e) {
                    if (mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        ),
      ]),
    );
  }
}

/// "My Labour Card" — a portable work record the worker owns, even if he leaves the app.
/// Contains NO phone, UPI or ID numbers, so it's safe to share with any contractor.
class LabourCardScreen extends StatelessWidget {
  const LabourCardScreen({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.myLabourCard, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: AsyncList<Json>(
        load: state.api.labourCard,
        builder: (ctx, c, _) {
          final trades = (c['trades'] as List).cast<String>();
          final b = c['breakdown'] as Json;
          final text = [
            'BuildCrew Labour Card · ${c['card_id']}',
            '${c['name'] ?? ''} — ${trades.map((t) => tradeLabel(l, t)).join(', ')}',
            '★ ${(c['rating'] as num).toStringAsFixed(1)} · ${l.ratingFromJobs(c['rating_count'] as int)} · ${l.jobsDone(c['completed_jobs'] as int)}',
            for (final bd in (c['badges'] as List).cast<String>()) badgeLabel(l, bd, c['rating'] as num, c['rating_count'] as int),
            '${l.rateQuality} ${b['quality']} · ${l.rateTimeliness} ${b['timeliness']} · ${l.rateBehaviour} ${b['behaviour']} · ${l.rateValue} ${b['value_for_money']}',
            if (c['eshram_registered'] == true) l.eshramRegistered,
            '${l.memberSince} ${c['member_since']} · ${c['city'] ?? ''}',
          ].join('\n');
          return ListView(padding: const EdgeInsets.all(20), children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF1C1917), Color(0xFF44403C)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(BC.rLg),
                boxShadow: BC.softShadow,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const IconBadge(Icons.construction_rounded, color: BC.brand, size: 36, solid: true),
                  const SizedBox(width: 10),
                  Text('BuildCrew', style: context.tt.titleLarge!.copyWith(color: Colors.white)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(c['card_id'] as String,
                        textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: context.tt.labelMedium!.copyWith(color: Colors.white54, fontFeatures: BC.tabular)),
                  ),
                ]),
                const SizedBox(height: 22),
                Text(c['name'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.headlineMedium!.copyWith(color: Colors.white)),
                Text(trades.map((t) => tradeLabel(l, t)).join(' · '),
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall!.copyWith(color: BC.pending)),
                const SizedBox(height: 20),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _CardStat(value: '★ ${(c['rating'] as num).toStringAsFixed(1)}', label: l.rating),
                  _CardStat(value: '${c['completed_jobs']}', label: l.jobsLabel),
                  _CardStat(value: 'L${c['verified_level']}', label: l.verified),
                ]),
                const SizedBox(height: 14),
                for (final bd in (c['badges'] as List).cast<String>())
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.workspace_premium_rounded, color: BC.pending, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(badgeLabel(l, bd, c['rating'] as num, c['rating_count'] as int),
                            style: context.tt.labelLarge!.copyWith(color: Colors.white, fontWeight: FontWeight.w500)),
                      ),
                    ]),
                  ),
                if (c['eshram_registered'] == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(children: [
                      const Icon(Icons.check_circle_rounded, color: Colors.white70, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(l.eshramRegistered, style: context.tt.bodyMedium!.copyWith(color: Colors.white70))),
                    ]),
                  ),
                const SizedBox(height: 12),
                Text('${l.memberSince} ${c['member_since']}', style: BC.caption.copyWith(color: Colors.white54)),
              ]),
            ),
            const SizedBox(height: 16),
            AppCard(padding: const EdgeInsets.all(BC.pad), child: RatingBars(breakdown: b)),
            const SizedBox(height: 16),
            PrimaryButton(onPressed: () => Share.share(text), icon: Icons.share_rounded, label: l.shareCard),
            const SizedBox(height: 10),
            Text(l.labourCardNote, textAlign: TextAlign.center, style: BC.subtle),
          ]);
        },
      ),
    );
  }
}

class _CardStat extends StatelessWidget {
  const _CardStat({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: context.tt.headlineSmall!.copyWith(color: Colors.white, fontFeatures: BC.tabular)),
          ),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.caption.copyWith(color: Colors.white54)),
        ]),
      );
}
