import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../common/profile.dart';
import '../common/update_ui.dart';

/// C1 — one dominant action (Post a Job), one secondary (Browse workers), then the user's jobs
/// with plain-language status. Full posting flow lands in Phase 3.
class CustomerHome extends StatefulWidget {
  const CustomerHome({super.key, required this.state});
  final AppState state;
  @override
  State<CustomerHome> createState() => _CustomerHomeState();
}

class _CustomerHomeState extends State<CustomerHome> {
  late Future<List<CustomerJob>> _jobs = widget.state.api.customerJobs();

  void _soon() => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).comingSoon)));

  (String, Color, Color, IconData) _status(L l, String s) => switch (s) {
        'open' => (l.statusOpen, BC.info, BC.infoSoft, Icons.campaign_rounded),
        'bidding' => (l.statusBidding, const Color(0xFF92400E), BC.pendingSoft, Icons.hourglass_top_rounded),
        'assigned' => (l.statusAssigned, BC.money, BC.moneySoft, Icons.handshake_rounded),
        'in_progress' => (l.statusInProgress, BC.info, BC.infoSoft, Icons.construction_rounded),
        'completed' => (l.statusCompleted, BC.brandDark, BC.brandSoft, Icons.star_rounded),
        'disputed' => (l.statusDisputed, BC.danger, const Color(0xFFFEE2E2), Icons.gavel_rounded),
        _ => (l.statusCancelled, BC.closed, BC.closedSoft, Icons.block_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final name = widget.state.user?.name?.split(' ').first ?? '';
    return UpdateAware(
      state: widget.state,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name.isEmpty ? l.appName : l.hello(name)),
          actions: [
            IconButton(
              iconSize: 30,
              icon: const Icon(Icons.account_circle_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(appBar: AppBar(), body: ProfileView(state: widget.state)),
              )),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: RefreshIndicator(
          color: BC.brand,
          onRefresh: () async {
            setState(() => _jobs = widget.state.api.customerJobs());
            await _jobs.catchError((_) => <CustomerJob>[]);
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            // Hero action
            Material(
              color: BC.brand,
              borderRadius: BorderRadius.circular(28),
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: _soon,
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
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _soon,
              icon: const Icon(Icons.groups_rounded),
              label: Text(l.browseWorkers),
            ),
            const SizedBox(height: 28),
            Text(l.activeJobs, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            FutureBuilder<List<CustomerJob>>(
              future: _jobs,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator(color: BC.brand)));
                }
                if (snap.hasError) return Text(l.errorNetwork, style: const TextStyle(color: BC.inkSoft));
                final jobs = snap.data!;
                if (jobs.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: BC.line)),
                    child: Text(l.noJobsYet, style: const TextStyle(fontSize: 16, color: BC.inkSoft)),
                  );
                }
                return Column(children: [
                  for (final j in jobs) ...[
                    _JobRow(job: j, status: _status(l, j.status)),
                    const SizedBox(height: 10),
                  ],
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.status});
  final CustomerJob job;
  final (String, Color, Color, IconData) status;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final trades = job.trades.toSet().toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            for (final t in trades.take(3))
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: TradeStyle.of(t).color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                child: Icon(TradeStyle.of(t).icon, color: TradeStyle.of(t).color, size: 22),
              ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(trades.map((t) => tradeLabel(l, t)).join(', '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.place_rounded, size: 18, color: BC.inkSoft),
            Text(' ${job.locality}', style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
            const Spacer(),
            StatusPill(label: status.$1, color: status.$2, bg: status.$3, icon: status.$4),
          ]),
          if (job.status == 'open' || job.status == 'bidding') ...[
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.people_alt_rounded, size: 20, color: job.bidCount > 0 ? BC.money : BC.inkFaint),
              const SizedBox(width: 6),
              Text(l.workersQuoted(job.bidCount),
                  style: TextStyle(fontWeight: FontWeight.w700, color: job.bidCount > 0 ? BC.money : BC.inkSoft)),
            ]),
          ],
        ]),
      ),
    );
  }
}
