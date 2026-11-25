import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../common/profile.dart';
import '../common/update_ui.dart';

/// Worker home — exactly four tabs, no hamburger, no nesting (design rule #2).
class WorkerShell extends StatefulWidget {
  const WorkerShell({super.key, required this.state});
  final AppState state;
  @override
  State<WorkerShell> createState() => _WorkerShellState();
}

class _WorkerShellState extends State<WorkerShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return UpdateAware(
      state: widget.state,
      child: Scaffold(
        body: SafeArea(
          child: IndexedStack(index: _tab, children: [
            JobsTab(state: widget.state),
            const ComingSoon(icon: Icons.receipt_long_rounded),
            const ComingSoon(icon: Icons.currency_rupee_rounded),
            ProfileView(state: widget.state),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            NavigationDestination(icon: const Icon(Icons.handyman_outlined), selectedIcon: const Icon(Icons.handyman), label: l.tabJobs),
            NavigationDestination(icon: const Icon(Icons.receipt_long_outlined), selectedIcon: const Icon(Icons.receipt_long), label: l.tabBids),
            NavigationDestination(icon: const Icon(Icons.currency_rupee_rounded), label: l.tabEarnings),
            NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: l.tabProfile),
          ],
        ),
      ),
    );
  }
}

/// S4 (Phase-1 cut): live feed from the API/demo data. Quote flow + job detail arrive in Phase 2.
class JobsTab extends StatefulWidget {
  const JobsTab({super.key, required this.state});
  final AppState state;
  @override
  State<JobsTab> createState() => _JobsTabState();
}

class _JobsTabState extends State<JobsTab> {
  late Future<List<FeedJob>> _future = widget.state.api.workerFeed();

  Future<void> _reload() async {
    setState(() => _future = widget.state.api.workerFeed());
    await _future.catchError((_) => <FeedJob>[]);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return RefreshIndicator(
      color: BC.brand,
      onRefresh: _reload,
      child: FutureBuilder<List<FeedJob>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator(color: BC.brand));
          }
          if (snap.hasError) {
            return ListView(padding: const EdgeInsets.all(32), children: [
              const Icon(Icons.wifi_off_rounded, size: 64, color: BC.inkFaint),
              const SizedBox(height: 12),
              Text(l.errorNetwork, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _reload, child: Text(l.retry)),
            ]);
          }
          final jobs = snap.data!;
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: jobs.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.jobsNear, style: Theme.of(context).textTheme.headlineMedium),
                        Text(l.jobsNearSub(jobs.length), style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
                      ]),
                    ),
                    SpeakButton(text: '${l.jobsNear}. ${l.jobsNearSub(jobs.length)}', lang: widget.state.language ?? 'hi'),
                  ]),
                );
              }
              return JobCard(job: jobs[i - 1]);
            },
          );
        },
      ),
    );
  }
}

class JobCard extends StatelessWidget {
  const JobCard({super.key, required this.job});
  final FeedJob job;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    String dur(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Photo strip — what the work looks like, before any words.
        SizedBox(
          height: 120,
          child: Row(children: [
            for (final (i, url) in job.thumbnails.take(3).indexed) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                child: Image.network(url, fit: BoxFit.cover, height: 120,
                    errorBuilder: (_, __, ___) => Container(color: BC.closedSoft, child: const Icon(Icons.image_outlined, color: BC.inkFaint)),
                    loadingBuilder: (_, child, p) => p == null ? child : Container(color: BC.closedSoft)),
              ),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in job.trades) TradeChip(t),
              if (job.audioSeconds != null)
                // Audio badge: shows a voice note exists + its data cost. Never auto-plays.
                StatusPill(
                  label: '🔊 ${dur(job.audioSeconds!)} · ${job.audioKb} KB',
                  color: BC.brandDark,
                  bg: BC.brandSoft,
                ),
            ]),
            const SizedBox(height: 12),
            DefaultTextStyle(
              style: const TextStyle(color: BC.inkSoft, fontSize: 15, fontWeight: FontWeight.w600),
              child: Row(children: [
                const Icon(Icons.place_rounded, size: 18, color: BC.inkSoft),
                const SizedBox(width: 4),
                Flexible(child: Text(job.locality, overflow: TextOverflow.ellipsis)),
                if (job.distanceKm != null) Text(' · ${l.kmAway(job.distanceKm!.toStringAsFixed(1))}'),
                const SizedBox(width: 12),
                const Icon(Icons.schedule_rounded, size: 18, color: BC.inkSoft),
                const SizedBox(width: 4),
                Text(timeAgo(l, job.postedAt)),
                const Spacer(),
                Text(l.workCount(job.workCount)),
              ]),
            ),
            const SizedBox(height: 14),
            job.alreadyBid
                ? StatusPill(label: l.alreadyQuoted, color: BC.closed, bg: BC.closedSoft, icon: Icons.check_rounded)
                : FilledButton.icon(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.comingSoon))),
                    icon: const Icon(Icons.currency_rupee_rounded),
                    label: Text(l.quotePrice),
                  ),
          ]),
        ),
      ]),
    );
  }
}
