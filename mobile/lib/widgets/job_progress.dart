import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'common.dart';

/// Where a customer's single job stands, in words a homeowner understands.
/// [step] 0..4 = Quotes · Hire & pay · Work · Check · Done.
class JobProgressInfo {
  const JobProgressInfo({required this.step, required this.title, required this.next, required this.color, required this.icon});
  final int step;
  final String title, next;
  final Color color;
  final IconData icon;
  static const total = 5;
  bool get complete => step >= total - 1;
}

Json? _assignmentOf(Json j) => (j['assignment'] as Json?) ?? ((j['detail'] as Json?)?['assignment'] as Json?);

/// Works on the job detail (has `assignment`) AND on a booking card (job list row, maybe with `detail`).
/// Null for team jobs and cancelled jobs (nothing to show).
JobProgressInfo? jobProgress(L l, Json job) {
  if (job['kind'] == 'team') return null;
  final status = job['status'] as String? ?? '';
  final a = _assignmentOf(job);
  final worker = (a?['worker'] as Map?)?['name'] as String? ?? job['worker_name'] as String? ?? '';
  final name = worker.split(' ').first;
  final pay = a?['payment'] as Map?;
  final refix = a?['kind'] == 'refix';
  final escrow = pay?['escrow_state'] as String? ?? job['payment_state'] as String? ?? (refix ? 'free' : 'created');
  final ratings = a?['ratings'] as Map?;
  final needsRating = job['needs_rating'] == true || (status == 'completed' && ratings != null && ratings['customer_to_worker'] == null && escrow == 'held');

  if (status == 'disputed') {
    return JobProgressInfo(step: 3, title: l.cxPrDisputed, next: l.cxPrDisputedNext, color: BC.danger, icon: Icons.gavel_rounded);
  }
  if (needsRating) {
    return JobProgressInfo(step: 3, title: l.cxPrRate(name), next: l.cxPrRateNext, color: BC.brandDark, icon: Icons.star_rounded);
  }
  if (status == 'completed') {
    return JobProgressInfo(step: 4, title: l.allDone, next: l.cxPrDoneNext, color: BC.money, icon: Icons.verified_rounded);
  }
  if (status == 'open' || status == 'bidding') {
    final n = (job['bid_count'] as num?)?.toInt() ?? ((job['bids'] as List?)?.length ?? 0);
    return n > 0
        ? JobProgressInfo(step: 0, title: l.cxPrQuotesReady(n), next: l.cxPrQuotesNext, color: BC.money, icon: Icons.request_quote_rounded)
        : JobProgressInfo(step: 0, title: l.cxPrWaitingQuotes, next: l.cxPrWaitingNext, color: BC.pendingInk, icon: Icons.hourglass_top_rounded);
  }
  if (status == 'assigned' || status == 'in_progress') {
    if (escrow == 'created') {
      return JobProgressInfo(step: 1, title: l.payToConfirm(name), next: l.cxPrPayNext, color: BC.brandDark, icon: Icons.account_balance_wallet_rounded);
    }
    if (a?['rework_open'] == true) {
      return JobProgressInfo(step: 2, title: l.cxPrFixing(name), next: l.cxPrFixingNext, color: BC.pendingInk, icon: Icons.replay_rounded);
    }
    if (a?['worker_done_at'] != null) {
      return JobProgressInfo(step: 3, title: l.cxPrCheck(name), next: l.cxPrCheckNext, color: BC.money, icon: Icons.task_alt_rounded);
    }
    if (status == 'in_progress') {
      return JobProgressInfo(step: 2, title: l.cxPrWorking(name), next: l.cxPrWorkingNext, color: BC.info, icon: Icons.construction_rounded);
    }
    final tr = a?['tracking'] as Map?;
    if (tr != null && tr['arrived'] != true) {
      return JobProgressInfo(step: 2, title: l.workerOnTheWay(name), next: l.cxPrArrivingNext, color: BC.info, icon: Icons.two_wheeler_rounded);
    }
    return JobProgressInfo(step: 2, title: l.cxPrComingSoon(name), next: l.cxPrComingNext, color: BC.info, icon: Icons.schedule_rounded);
  }
  return null;
}

List<(String, IconData)> _steps(L l) => [
      (l.cxStepQuotes, Icons.request_quote_rounded),
      (l.cxStepHire, Icons.handshake_rounded),
      (l.cxStepWork, Icons.construction_rounded),
      (l.cxStepCheck, Icons.fact_check_rounded),
      (l.cxStepDone, Icons.verified_rounded),
    ];

/// The big progress header of the customer job screen: current step highlighted, one big sentence,
/// one line "what happens next".
class JobProgressHeader extends StatelessWidget {
  const JobProgressHeader({super.key, required this.info});
  final JobProgressInfo info;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final steps = _steps(l);
    final c = info.color;
    return Container(
      key: const ValueKey('jobProgressHeader'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: BC.card, borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: c.withValues(alpha: 0.4), width: 1.5)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CircleAvatar(radius: 26, backgroundColor: c, child: Icon(info.icon, color: Colors.white, size: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.cxStepOf(info.step + 1, JobProgressInfo.total), style: context.tt.labelMedium!.copyWith(color: c, fontWeight: FontWeight.w700)),
              Text(info.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tt.headlineSmall),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Column(children: [
                Row(children: [
                  Expanded(child: Container(height: 3, color: i == 0 ? Colors.transparent : (i <= info.step ? BC.money : BC.line))),
                  _Dot(done: i < info.step || (info.complete && i == info.step), current: i == info.step && !info.complete, color: c, icon: steps[i].$2),
                  Expanded(child: Container(height: 3, color: i == steps.length - 1 ? Colors.transparent : (i < info.step ? BC.money : BC.line))),
                ]),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(steps[i].$1,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(fontSize: 12, fontWeight: i == info.step ? FontWeight.w800 : FontWeight.w600, color: i <= info.step ? BC.ink : BC.inkFaint)),
                ),
              ]),
            ),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(BC.r)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.arrow_circle_right_rounded, color: c, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.cxWhatNext, style: context.tt.labelMedium!.copyWith(color: BC.inkSoft)),
                Text(info.next, style: context.tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600, height: 1.35)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.done, required this.current, required this.color, required this.icon});
  final bool done, current;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final size = current ? 36.0 : 28.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? BC.money : (current ? color : BC.closedSoft),
        border: current ? Border.all(color: color.withValues(alpha: 0.3), width: 4) : null,
      ),
      child: Icon(done ? Icons.check_rounded : icon, size: current ? 20 : 16, color: (done || current) ? Colors.white : BC.inkFaint),
    );
  }
}

/// Compact version for booking cards: five little bars, filled up to the current step.
class JobProgressBar extends StatelessWidget {
  const JobProgressBar({super.key, required this.info});
  final JobProgressInfo info;
  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < JobProgressInfo.total; i++)
          Expanded(
            child: Container(
              height: 6,
              margin: EdgeInsets.only(right: i == JobProgressInfo.total - 1 ? 0 : 4),
              decoration: BoxDecoration(
                color: i < info.step ? BC.money : (i == info.step ? info.color : BC.line),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
      ]);
}
