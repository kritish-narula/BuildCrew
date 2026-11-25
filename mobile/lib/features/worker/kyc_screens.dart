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
    Widget step(int n, String title, bool done, {VoidCallback? onTap, String? status}) => ListTile(
          minTileHeight: 64,
          onTap: done ? null : onTap,
          leading: CircleAvatar(
            backgroundColor: done ? BC.money : BC.closedSoft,
            child: done ? const Icon(Icons.check_rounded, color: Colors.white) : Text('$n', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: status == null ? null : Text(status),
          trailing: done || onTap == null ? null : const Icon(Icons.chevron_right_rounded),
        );
    final doc = kyc['doc_status'] as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(l.verification, style: Theme.of(context).textTheme.titleLarge),
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
      ),
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
      appBar: AppBar(title: Text(l.kycL1Title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        Text(l.kycL1Why, style: const TextStyle(color: BC.inkSoft, fontSize: 16)),
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
              Text(l.takeSelfie, style: const TextStyle(fontWeight: FontWeight.w700, color: BC.brandDark, fontSize: 16)),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        TextField(controller: _name, textCapitalization: TextCapitalization.words, style: const TextStyle(fontSize: 20),
            decoration: InputDecoration(labelText: l.yourName, prefixIcon: const Icon(Icons.person_rounded)), onChanged: (_) => setState(() {})),
        const SizedBox(height: 14),
        TextField(controller: _upi, keyboardType: TextInputType.emailAddress, autocorrect: false, style: const TextStyle(fontSize: 20),
            decoration: InputDecoration(labelText: l.upiId, hintText: 'name@okaxis', prefixIcon: const Icon(Icons.account_balance_wallet_rounded)),
            onChanged: (_) => setState(() {})),
        const SizedBox(height: 20),
        Text(l.yourSkills, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in const ['mason', 'plumber', 'electrician', 'carpenter', 'painter', 'helper'])
            FilterChip(
              selected: _trades.contains(t),
              onSelected: (v) => setState(() => v ? _trades.add(t) : _trades.remove(t)),
              avatar: Icon(TradeStyle.of(t).icon, color: TradeStyle.of(t).color),
              label: Text(tradeLabel(l, t), style: const TextStyle(fontSize: 16)),
            ),
        ]),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.lock_rounded, color: BC.info, text: l.kycPrivacy),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _valid && !_busy ? _save : null,
          child: _busy ? const CircularProgressIndicator(color: Colors.white) : Text(l.save),
        ),
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
      appBar: AppBar(title: Text(l.kycL2Title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        Text(l.kycL2Why, style: const TextStyle(color: BC.inkSoft, fontSize: 16)),
        const SizedBox(height: 16),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'aadhaar', label: Text(l.aadhaar), icon: const Icon(Icons.fingerprint_rounded)),
            ButtonSegment(value: 'pan', label: Text(l.pan), icon: const Icon(Icons.credit_card_rounded)),
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
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: BC.line, width: 2)),
            clipBehavior: Clip.antiAlias,
            child: _photo == null
                ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.document_scanner_rounded, size: 56, color: BC.brand),
                    const SizedBox(height: 8),
                    Text(l.photoOfCard, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  ])
                : AppImage(_photo, width: double.infinity),
          ),
        ),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.lock_rounded, color: BC.info, text: l.kycL2Privacy),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _photo == null || _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final key = (await widget.state.api.upload('kyc', _photo!))['key'] as String;
                    await widget.state.api.kycLevel2(_type, key);
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: _busy ? const CircularProgressIndicator(color: Colors.white) : Text(l.submitForReview),
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
      appBar: AppBar(title: Text(l.myLabourCard)),
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
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: BC.brand, borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.construction_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  const Text('BuildCrew', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                  const Spacer(),
                  Text(c['card_id'] as String, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w700, letterSpacing: 1)),
                ]),
                const SizedBox(height: 20),
                Text(c['name'] as String? ?? '', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                Text(trades.map((t) => tradeLabel(l, t)).join(' · '), style: const TextStyle(color: BC.pending, fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 18),
                Row(children: [
                  _CardStat(value: '★ ${(c['rating'] as num).toStringAsFixed(1)}', label: l.rating),
                  _CardStat(value: '${c['completed_jobs']}', label: l.jobsLabel),
                  _CardStat(value: 'L${c['verified_level']}', label: l.verified),
                ]),
                const SizedBox(height: 14),
                for (final bd in (c['badges'] as List).cast<String>())
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('🏅 ${badgeLabel(l, bd, c['rating'] as num, c['rating_count'] as int)}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                if (c['eshram_registered'] == true)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('✓ ${l.eshramRegistered}', style: const TextStyle(color: Colors.white70))),
                const SizedBox(height: 10),
                Text('${l.memberSince} ${c['member_since']}', style: const TextStyle(color: Colors.white38, fontSize: 13)),
              ]),
            ),
            const SizedBox(height: 20),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: RatingBars(breakdown: b))),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: () => Share.share(text), icon: const Icon(Icons.share_rounded), label: Text(l.shareCard)),
            const SizedBox(height: 8),
            Text(l.labourCardNote, textAlign: TextAlign.center, style: const TextStyle(color: BC.inkSoft)),
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
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
        ]),
      );
}
