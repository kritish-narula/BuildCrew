import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../common/profile.dart';
import '../common/update_ui.dart';
import 'customer_job.dart';
import 'post_job.dart';
import 'workers.dart';

/// C1 — one dominant action (Post a Job), one secondary (Browse workers), then the user's
/// jobs: active ones with "N workers have quoted", completed ones with "Rate to release payment".
class CustomerHome extends StatefulWidget {
  const CustomerHome({super.key, required this.state});
  final AppState state;
  @override
  State<CustomerHome> createState() => _CustomerHomeState();
}

class _CustomerHomeState extends State<CustomerHome> {
  Key _listKey = UniqueKey();
  void _refresh() => setState(() => _listKey = UniqueKey());

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final s = widget.state;
    final name = s.user?.name?.split(' ').first ?? '';
    return UpdateAware(
      state: s,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name.isEmpty ? l.appName : l.hello(name)),
          actions: [
            IconButton(iconSize: 28, tooltip: l.payments, icon: const Icon(Icons.receipt_long_rounded), onPressed: () => _open(PaymentsScreen(state: s))),
            IconButton(
              iconSize: 30,
              icon: const Icon(Icons.account_circle_rounded),
              onPressed: () => _open(Scaffold(appBar: AppBar(), body: ProfileView(state: s))),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: AsyncList<List<Json>>(
          key: _listKey,
          load: s.api.customerJobs,
          builder: (ctx, jobs, reload) {
            final needRating = jobs.where((j) => j['needs_rating'] == true).toList();
            final active = jobs.where((j) => const ['open', 'bidding', 'assigned', 'in_progress', 'disputed'].contains(j['status']) ).toList();
            final past = jobs.where((j) => !active.contains(j) && !needRating.contains(j)).toList();
            return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
              _PostHero(onTap: () => _open(PostJobScreen(state: s))),
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: () => _open(BrowseWorkersScreen(state: s)), icon: const Icon(Icons.groups_rounded), label: Text(l.browseWorkers)),
              for (final j in needRating) ...[
                const SizedBox(height: 14),
                InfoBanner(
                  icon: Icons.star_rounded,
                  color: BC.brandDark,
                  text: l.rateWorkerBanner(j['worker_name'] as String? ?? ''),
                  action: l.rateNow,
                  onTap: () => _open(CustomerJobScreen(state: s, jobId: j['id'] as String)),
                ),
              ],
              const SizedBox(height: 24),
              if (jobs.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: BC.line)),
                  child: Text(l.noJobsYet, style: const TextStyle(fontSize: 16, color: BC.inkSoft)),
                ),
              if (active.isNotEmpty) ...[
                Text(l.activeJobs, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                for (final j in active) ...[JobRow(job: j, onTap: () => _open(CustomerJobScreen(state: s, jobId: j['id'] as String))), const SizedBox(height: 10)],
              ],
              if (past.isNotEmpty || needRating.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(l.completedJobs, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                for (final j in [...needRating, ...past]) ...[
                  JobRow(job: j, onTap: () => _open(CustomerJobScreen(state: s, jobId: j['id'] as String))),
                  const SizedBox(height: 10),
                ],
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class _PostHero extends StatelessWidget {
  const _PostHero({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Material(
      color: BC.brand,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.postJob, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(l.postJobSub, style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 16)),
                const SizedBox(height: 16),
                Row(children: [
                  for (final ic in [Icons.photo_camera_rounded, Icons.mic_rounded, Icons.currency_rupee_rounded])
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
                      child: Icon(ic, color: Colors.white, size: 22),
                    ),
                ]),
              ]),
            ),
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: const Icon(Icons.add_rounded, color: BC.brand, size: 44),
            ),
          ]),
        ),
      ),
    );
  }
}

class JobRow extends StatelessWidget {
  const JobRow({super.key, required this.job, required this.onTap});
  final Json job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final trades = (job['trades'] as List).cast<String>().toSet().toList();
    final status = job['status'] as String;
    final needsRating = job['needs_rating'] == true;
    final (label, fg, bg, icon) = needsRating
        ? (l.statusCompleted, BC.brandDark, BC.brandSoft, Icons.star_rounded)
        : switch (status) {
            'open' => (l.statusOpen, BC.info, BC.infoSoft, Icons.campaign_rounded),
            'bidding' => (l.statusBidding, const Color(0xFF92400E), BC.pendingSoft, Icons.hourglass_top_rounded),
            'assigned' => (l.statusAssigned, BC.money, BC.moneySoft, Icons.handshake_rounded),
            'in_progress' => (l.statusInProgress, BC.info, BC.infoSoft, Icons.construction_rounded),
            'completed' => (l.statusPaid, BC.money, BC.moneySoft, Icons.check_circle_rounded),
            'disputed' => (l.statusDisputed, BC.danger, const Color(0xFFFEE2E2), Icons.gavel_rounded),
            _ => (l.statusCancelled, BC.closed, BC.closedSoft, Icons.block_rounded),
          };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(14), child: AppImage(job['thumbnail'] as String?, width: 64, height: 64)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(trades.map((t) => tradeLabel(l, t)).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('📍 ${job['locality']}${job['worker_name'] != null ? ' · ${job['worker_name']}' : ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(children: [
                  Flexible(child: StatusPill(label: label, color: fg, bg: bg, icon: icon)),
                  if (status == 'open' || status == 'bidding') ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(l.workersQuoted(job['bid_count'] as int), overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w700, color: (job['bid_count'] as int) > 0 ? BC.money : BC.inkSoft)),
                    ),
                  ],
                ]),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
          ]),
        ),
      ),
    );
  }
}
