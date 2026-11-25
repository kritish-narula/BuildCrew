import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../../widgets/trust_widgets.dart';

/// Worker growth cards: skill level + weekly streak, "Paid today" (same-day pay) and police verification.

/// "Skilled", a progress bar to the next level and exactly what is still needed; weekly streak; re-fix record.
class LevelCard extends StatelessWidget {
  const LevelCard({super.key, required this.level, this.streak, this.record});
  final Json level;
  final Json? streak;
  final Json? record;

  String _need(L l, Json n) => switch (n['kind']) {
        'jobs' => l.levelNeedJobs((n['need'] as num).toInt()),
        'rating' => l.levelNeedRating((n['need'] as num).toStringAsFixed(1)),
        _ => l.levelNeedRefix((n['need'] as num).toInt()),
      };

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final code = level['code'] as String;
    final color = levelColor(code);
    final next = level['next'] as Map?;
    final needs = ((level['needs'] as List?) ?? const []).cast<Json>();
    final weeks = (streak?['weeks'] as num?)?.toInt() ?? 0;
    final mult = (level['fair_multiplier'] as num?)?.toDouble() ?? 1.0;
    final refixes = (record?['refixes'] as num?)?.toInt() ?? 0;
    final jobs = (record?['jobs'] as num?)?.toInt() ?? 0;
    return AppCard(
      padding: const EdgeInsets.all(BC.pad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBadge(Icons.military_tech_rounded, color: color, size: 48, solid: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.levelCardTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.caption),
              Text(levelLabel(l, code), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.headlineSmall),
            ]),
          ),
          if (weeks > 0) ...[
            const SizedBox(width: 8),
            Flexible(child: StatusPill(label: '🔥 ${l.streakWeeks(weeks)}', color: BC.brandDark, bg: BC.brandSoft)),
          ],
        ]),
        const SizedBox(height: 14),
        if (next != null) ...[
          Text(l.levelNext(levelLabel(l, next['code'] as String)), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
                key: const ValueKey('levelProgress'), value: ((level['progress'] as num?) ?? 0).toDouble().clamp(0.0, 1.0), minHeight: 10, color: color, backgroundColor: BC.closedSoft),
          ),
          const SizedBox(height: 8),
          for (final n in needs)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 3), child: Icon(Icons.arrow_right_rounded, size: 20, color: BC.inkSoft)),
                const SizedBox(width: 2),
                Expanded(child: Text(_need(l, n), maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle)),
              ]),
            ),
        ] else
          Text(l.levelTop, style: BC.subtle),
        if (mult > 1.0) ...[
          const SizedBox(height: 8),
          Text(l.levelFairNote(((mult - 1) * 100).round()), style: BC.caption),
        ],
        if (weeks > 0 && streak?['alive_this_week'] != true) ...[
          const SizedBox(height: 8),
          Text(l.streakKeep, style: BC.caption),
        ],
        if (record != null && jobs > 0) ...[
          const Divider(height: 24),
          Row(children: [
            const Icon(Icons.build_circle_outlined, size: 20, color: BC.inkSoft),
            const SizedBox(width: 8),
            Expanded(child: Text(l.warrantyRecord(refixes, jobs), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium)),
          ]),
        ],
      ]),
    );
  }
}

/// Same-day pay: today's automatic payouts as a small timeline (processing -> paid).
class PaidTodayCard extends StatelessWidget {
  const PaidTodayCard({super.key, required this.paidToday});
  final Json paidToday;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final items = ((paidToday['items'] as List?) ?? const []).cast<Json>();
    if (items.isEmpty) return const SizedBox.shrink();
    return AppCard(
      padding: const EdgeInsets.all(BC.pad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBadge(Icons.bolt_rounded, color: BC.money, size: 40),
          const SizedBox(width: 12),
          Expanded(child: Text(l.paidToday, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge)),
          const SizedBox(width: 8),
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(inr(paidToday['total_inr'] as num), maxLines: 1, style: context.tt.headlineSmall!.copyWith(color: BC.money, fontFeatures: BC.tabular)))),
        ]),
        const SizedBox(height: 10),
        for (final (i, p) in items.indexed)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 28,
                child: Column(children: [
                  Container(width: 2, height: 6, color: i == 0 ? Colors.transparent : BC.line),
                  p['state'] == 'paid'
                      ? const Icon(Icons.check_circle_rounded, color: BC.money, size: 22)
                      : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: BC.pending)),
                  Expanded(child: Container(width: 2, color: i == items.length - 1 ? Colors.transparent : BC.line)),
                ]),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10, top: 2),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(inr(p['amount_inr'] as num), maxLines: 1, style: context.tt.titleMedium!.copyWith(fontFeatures: BC.tabular)),
                    Text(p['state'] == 'paid' ? l.payoutPaid('${p['upi']}') : l.payoutProcessing('${p['upi']}'), maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
                  ]),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Profile -> Verification: optional police verification (a partner checks Aadhaar + address; admin decides).
class PoliceStep extends StatefulWidget {
  const PoliceStep({super.key, required this.state, required this.police, required this.kycLevel, required this.onChanged});
  final AppState state;
  final Json police; // {status: none|pending|verified|rejected, note, requested_at}
  final int kycLevel;
  final Future<void> Function() onChanged;
  @override
  State<PoliceStep> createState() => _PoliceStepState();
}

class _PoliceStepState extends State<PoliceStep> {
  bool _busy = false;

  Future<void> _request() async {
    setState(() => _busy = true);
    try {
      await widget.state.api.requestPoliceVerification();
      await widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: BC.money, content: Text(L.of(context).policeRequested, style: const TextStyle(fontSize: 15, color: Colors.white))));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final status = widget.police['status'] as String? ?? 'none';
    final note = (widget.police['note'] as String?) ?? '';
    final (text, color) = switch (status) {
      'pending' => (l.policePending, BC.pendingInk),
      'verified' => (l.policeDone, BC.money),
      'rejected' => (l.policeRejected(note), BC.danger),
      _ => (widget.kycLevel >= 1 ? l.policeSub : l.policeNeedKyc, BC.inkSoft),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(BC.pad, 10, BC.pad, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: status == 'verified' ? BC.money : BC.closedSoft,
            child: Icon(Icons.shield_rounded, size: 20, color: status == 'verified' ? Colors.white : BC.inkFaint),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.policeTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium),
              const SizedBox(height: 2),
              Text(text, maxLines: 4, overflow: TextOverflow.ellipsis, style: BC.subtle.copyWith(color: color)),
            ]),
          ),
        ]),
        if (status == 'none' || status == 'rejected') ...[
          const SizedBox(height: 10),
          SecondaryButton(
            icon: Icons.shield_outlined,
            label: status == 'rejected' ? l.policeRetry : l.policeGet,
            onPressed: _busy || widget.kycLevel < 1 ? null : _request,
          ),
        ],
      ]),
    );
  }
}
