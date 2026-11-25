import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/location.dart';
import '../../core/outbox.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../common/profile.dart';
import '../common/update_ui.dart';
import 'assignment_screen.dart';
import 'job_detail.dart';
import 'kyc_screens.dart';

/// Worker home — exactly four tabs, no hamburger, no nesting (design rule #2).
/// Every screen answers: "what do I do next to earn money?"
class WorkerShell extends StatefulWidget {
  const WorkerShell({super.key, required this.state});
  final AppState state;
  @override
  State<WorkerShell> createState() => _WorkerShellState();
}

class _WorkerShellState extends State<WorkerShell> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Outbox.instance.init(widget.state.api);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) Outbox.instance.flush();
    if (s == AppLifecycleState.paused) AudioHub.instance.stopAll();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return UpdateAware(
      state: widget.state,
      child: Scaffold(
        body: SafeArea(
          child: IndexedStack(index: _tab, children: [
            JobsTab(state: widget.state),
            BidsTab(state: widget.state, active: _tab == 1),
            EarningsTab(state: widget.state, active: _tab == 2),
            WorkerProfileTab(state: widget.state, active: _tab == 3),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            AudioHub.instance.stopAll();
            setState(() => _tab = i);
          },
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

/// Small chip that appears whenever something is waiting for network.
class PendingChip extends StatelessWidget {
  const PendingChip({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Outbox.instance,
        builder: (ctx, _) => Outbox.instance.pending == 0
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: StatusPill(label: L.of(context).pendingSync(Outbox.instance.pending), color: const Color(0xFF92400E),
                    bg: BC.pendingSoft, icon: Icons.cloud_upload_outlined),
              ),
      );
}

// ================================================================== S4 Jobs
class JobsTab extends StatelessWidget {
  const JobsTab({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return AsyncList<(List<Json>, List<Json>)>(
      load: () async {
        // "Near you" must mean near the worker's real position, not a saved home address.
        final p = await LocationService.quiet();
        if (p != null) {
          try {
            await state.api.updateMyLocation(p.latitude, p.longitude);
          } catch (_) {}
        }
        return (await state.api.workerFeed(), await state.api.assignments());
      },
      builder: (ctx, data, reload) {
        final (jobs, work) = data;
        final active = work.where((a) => const ['assigned', 'in_progress'].contains((a['job'] as Json)['status'])).toList();
        final toRate = work.where((a) => (a['job'] as Json)['status'] == 'completed' && (a['ratings'] as Map)['worker_to_customer'] == null).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          const PendingChip(),
          if (LocationService.last == null) ...[
            InfoBanner(
              icon: Icons.location_searching_rounded,
              color: BC.info,
              text: l.turnOnLocationForJobs,
              action: l.turnOn,
              onTap: () async {
                final p = await LocationService.get(context, precise: false);
                if (p != null) {
                  await state.api.updateMyLocation(p.latitude, p.longitude);
                  await reload();
                }
              },
            ),
            const SizedBox(height: 14),
          ],
          if (state.user != null && state.user!.kycLevel < 1 && work.isNotEmpty) ...[
            KycNudge(state: state, onDone: reload),
            const SizedBox(height: 14),
          ],
          // "Today's work" first: the job that already pays beats new jobs.
          for (final a in [...active, ...toRate]) ...[
            ActiveWorkCard(a: a, onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AssignmentScreen(state: state, assignmentId: a['id'] as String)));
              await reload();
            }),
            const SizedBox(height: 14),
          ],
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.jobsNear, style: Theme.of(context).textTheme.headlineMedium),
                Text(l.jobsNearSub(jobs.length), style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
              ]),
            ),
            SpeakButton(text: '${l.jobsNear}. ${l.jobsNearSub(jobs.length)}', lang: state.language ?? 'hi'),
          ]),
          const SizedBox(height: 12),
          if (jobs.isEmpty)
            EmptyState(icon: Icons.search_off_rounded, text: l.noJobsNear)
          else
            for (final j in jobs) ...[
              JobCard(job: j, onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => JobDetailScreen(state: state, jobId: j['id'] as String)));
                await reload();
              }),
              const SizedBox(height: 14),
            ],
        ]);
      },
    );
  }
}

class ActiveWorkCard extends StatelessWidget {
  const ActiveWorkCard({super.key, required this.a, required this.onTap});
  final Json a;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final job = a['job'] as Json;
    final status = job['status'] as String;
    final unpaid = (a['payment'] as Map?)?['escrow_state'] == 'created';
    final (label, icon) = switch (status) {
      'assigned' when unpaid => (l.waitingForPayment, Icons.hourglass_top_rounded),
      'assigned' => (l.workAssigned, Icons.event_available_rounded),
      'in_progress' => (l.workInProgress, Icons.construction_rounded),
      _ => (l.rateCustomerCta, Icons.star_rounded),
    };
    return Material(
      color: BC.money,
      borderRadius: BorderRadius.circular(BC.rLg),
      child: InkWell(
        borderRadius: BorderRadius.circular(BC.rLg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, color: Colors.white, size: 32),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text('${job['locality']} · ${inr(a['price_inr'] as num)}',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 32),
          ]),
        ),
      ),
    );
  }
}

class JobCard extends StatelessWidget {
  const JobCard({super.key, required this.job, required this.onTap});
  final Json job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final thumbs = (job['thumbnails'] as List).cast<String>();
    final audio = job['audio'] as Map?;
    final trades = [for (final t in job['trades'] as List) (t as Map)['code'] as String];
    final dist = job['distance_km'] as num?;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Photo strip — what the work looks like, before any words.
          SizedBox(
            height: 120,
            child: Row(children: [
              for (final (i, url) in thumbs.take(3).indexed) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(child: AppImage(url, height: 120)),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final t in trades) TradeChip(t),
                // Audio badge: a voice note exists + its data cost. Never auto-plays in the feed.
                if (audio != null)
                  StatusPill(label: '🔊 ${mmss(audio['total_seconds'] as int)} · ${audio['total_kb']} KB', color: BC.brandDark, bg: BC.brandSoft),
              ]),
              const SizedBox(height: 12),
              DefaultTextStyle(
                style: const TextStyle(color: BC.inkSoft, fontSize: 15, fontWeight: FontWeight.w600),
                child: Row(children: [
                  const Icon(Icons.place_rounded, size: 18, color: BC.inkSoft),
                  const SizedBox(width: 4),
                  Flexible(child: Text(job['locality'] as String, overflow: TextOverflow.ellipsis)),
                  if (dist != null) Text(' · ${l.kmAway(dist.toStringAsFixed(1))}'),
                  const SizedBox(width: 12),
                  const Icon(Icons.schedule_rounded, size: 18, color: BC.inkSoft),
                  const SizedBox(width: 4),
                  Text(timeAgo(l, DateTime.parse(job['posted_at'] as String))),
                  const Spacer(),
                  Text(l.workCount(job['work_count'] as int)),
                ]),
              ),
              const SizedBox(height: 14),
              ListenableBuilder(
                listenable: Outbox.instance,
                builder: (ctx, _) {
                  if (Outbox.instance.hasPendingFor('bid', job['id'] as String)) {
                    return StatusPill(label: l.bidSavedOffline, color: const Color(0xFF92400E), bg: BC.pendingSoft, icon: Icons.cloud_upload_outlined);
                  }
                  if (job['already_bid'] == true) {
                    return StatusPill(label: '${l.alreadyQuoted} · ${inr(job['my_price_inr'] as num?)}', color: const Color(0xFF92400E),
                        bg: BC.pendingSoft, icon: Icons.hourglass_top_rounded);
                  }
                  return FilledButton.icon(onPressed: onTap, icon: const Icon(Icons.currency_rupee_rounded), label: Text(l.quotePrice));
                },
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ================================================================== S6 My Bids
class BidsTab extends StatelessWidget {
  const BidsTab({super.key, required this.state, required this.active});
  final AppState state;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (!active) return const SizedBox.shrink(); // load when opened (saves data)
    return AsyncList<List<Json>>(
      load: state.api.myBids,
      builder: (ctx, bids, reload) => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        Text(l.tabBids, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        const PendingChip(),
        if (bids.isEmpty) EmptyState(icon: Icons.receipt_long_rounded, text: l.noBidsYet),
        for (final b in bids) ...[
          _BidRow(state: state, bid: b, onChanged: reload),
          const SizedBox(height: 10),
        ],
      ]),
    );
  }
}

class _BidRow extends StatelessWidget {
  const _BidRow({required this.state, required this.bid, required this.onChanged});
  final AppState state;
  final Json bid;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final job = bid['job'] as Json;
    final status = bid['status'] as String;
    // Colour alone tells the story: amber waiting, green won, grey not selected.
    final (label, fg, bg, icon) = switch (status) {
      'pending' => (l.bidPending, const Color(0xFF92400E), BC.pendingSoft, Icons.hourglass_top_rounded),
      'accepted' => (l.bidAccepted, BC.money, BC.moneySoft, Icons.check_circle_rounded),
      'withdrawn' => (l.bidWithdrawn, BC.closed, BC.closedSoft, Icons.undo_rounded),
      _ => (l.bidNotSelected, BC.closed, BC.closedSoft, Icons.do_not_disturb_on_rounded),
    };
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(BC.rLg),
        onTap: () async {
          final aid = bid['assignment_id'] as String?;
          await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => aid != null ? AssignmentScreen(state: state, assignmentId: aid) : JobDetailScreen(state: state, jobId: job['id'] as String)));
          await onChanged();
        },
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: fg, width: 6))),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ClipRRect(borderRadius: BorderRadius.circular(12), child: AppImage(job['thumbnail'] as String?, width: 56, height: 56)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(inr(bid['price_inr'] as num), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
                  Text('${(job['trades'] as List).toSet().map((t) => tradeLabel(l, t as String)).join(', ')} · ${job['locality']}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              StatusPill(label: label, color: fg, bg: bg, icon: icon),
              const Spacer(),
              if (status == 'pending')
                TextButton(
                  onPressed: () async {
                    try {
                      await state.api.withdrawBid(bid['id'] as String);
                      await onChanged();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: Text(l.withdrawBid),
                ),
            ]),
            if (status == 'rejected')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.bidNotSelectedMsg, style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
              ),
          ]),
        ),
      ),
    );
  }
}

// ================================================================== S7 Earnings
class EarningsTab extends StatelessWidget {
  const EarningsTab({super.key, required this.state, required this.active});
  final AppState state;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final lang = state.language ?? 'hi';
    if (!active) return const SizedBox.shrink();
    return AsyncList<Json>(
      load: state.api.earnings,
      builder: (ctx, e, reload) {
        final kyc = e['kyc'] as Json;
        final available = e['available_inr'] as num;
        final history = (e['history'] as List).cast<Json>();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          // One dominant number.
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(28)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(l.availableBalance, style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                SpeakButton(text: l.balanceSpeech(inr(available)), lang: lang, size: 40),
              ]),
              const SizedBox(height: 6),
              FittedBox(
                child: Text(inr(available), style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
              ),
              const SizedBox(height: 4),
              if ((e['held_inr'] as num) > 0)
                Text(l.heldInEscrow(inr(e['held_inr'] as num)), style: const TextStyle(color: BC.pending, fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: available <= 0
                    ? null
                    : () async {
                        if (kyc['needs_level1'] == true) {
                          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel1Screen(state: state)));
                          await reload();
                          return;
                        }
                        try {
                          final r = await state.api.withdraw();
                          if (!context.mounted) return;
                          await showDialog<void>(
                            context: context,
                            builder: (c) => AlertDialog(
                              icon: const Icon(Icons.check_circle_rounded, color: BC.money, size: 56),
                              title: Text(l.withdrawDone(inr(r['amount_inr'] as num))),
                              content: Text(l.withdrawTo(r['upi'] as String), textAlign: TextAlign.center),
                              actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.close))],
                            ),
                          );
                          await reload();
                        } catch (err) {
                          if (context.mounted) showError(context, err);
                        }
                      },
                style: FilledButton.styleFrom(backgroundColor: BC.money, disabledBackgroundColor: Colors.white12, disabledForegroundColor: Colors.white38),
                icon: const Icon(Icons.account_balance_rounded),
                label: Text(e['upi'] == null ? l.withdrawUpi : l.withdrawToUpi(e['upi'] as String)),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          if (kyc['nudge_level2'] == true) ...[
            InfoBanner(icon: Icons.verified_user_rounded, color: BC.info, text: l.kycL2Nudge, action: l.addNow, onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel2Screen(state: state)));
              await reload();
            }),
            const SizedBox(height: 14),
          ],
          Row(children: [
            Expanded(child: _MiniStat(label: l.totalEarned, value: inr(e['total_earned_inr'] as num))),
            const SizedBox(width: 10),
            Expanded(child: _MiniStat(label: l.paidToBank, value: inr(e['paid_out_inr'] as num))),
          ]),
          const SizedBox(height: 20),
          Text(l.paymentHistory, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (history.isEmpty) EmptyState(icon: Icons.payments_outlined, text: l.noPaymentsYet),
          for (final h in history)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                minTileHeight: 72,
                // Tap a row to hear it read aloud.
                onTap: () => Speaker.instance.say(_speech(l, h), lang),
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor: h['kind'] == 'payout' ? BC.infoSoft : (h['state'] == 'held' ? BC.pendingSoft : BC.moneySoft),
                  child: Icon(h['kind'] == 'payout' ? Icons.account_balance_rounded : (h['state'] == 'held' ? Icons.lock_clock_rounded : Icons.south_west_rounded),
                      color: h['kind'] == 'payout' ? BC.info : (h['state'] == 'held' ? const Color(0xFF92400E) : BC.money)),
                ),
                title: Text(inr(h['amount_inr'] as num), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
                subtitle: Text(_subtitle(l, h), style: const TextStyle(fontSize: 14)),
                trailing: const Icon(Icons.volume_up_rounded, color: BC.inkFaint),
              ),
            ),
        ]);
      },
    );
  }

  String _subtitle(L l, Json h) {
    final date = (h['date'] as String).substring(0, 10);
    if (h['kind'] == 'payout') return '${l.sentToUpi(h['upi'] as String? ?? '')} · $date';
    final where = '${(h['trades'] as List).map((t) => tradeLabel(l, t as String)).join(', ')} · ${h['locality']}';
    return '${h['state'] == 'held' ? l.waitingForRating : l.received} · $where';
  }

  String _speech(L l, Json h) => h['kind'] == 'payout'
      ? l.speechPayout(inr(h['amount_inr'] as num))
      : (h['state'] == 'held' ? l.speechHeld(inr(h['amount_inr'] as num)) : l.speechReceived(inr(h['amount_inr'] as num)));
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
        ]),
      );
}

// ================================================================== S8 Profile
class WorkerProfileTab extends StatelessWidget {
  const WorkerProfileTab({super.key, required this.state, required this.active});
  final AppState state;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (!active) return const SizedBox.shrink();
    return AsyncList<Json>(
      load: state.api.workerProfile,
      builder: (ctx, p, reload) {
        final b = p['breakdown'] as Json;
        final badges = (p['badges'] as List).cast<String>();
        final history = (p['history'] as List).cast<Json>();
        final kyc = p['kyc'] as Json;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          Row(children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: BC.brand,
              foregroundImage: p['selfie'] != null && (p['selfie'] as String).startsWith('http') ? NetworkImage(p['selfie'] as String) : null,
              child: Text(initials(p['name'] as String? ?? ''), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'] as String? ?? '+91 ${p['phone']}', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 6, children: [for (final t in p['trades'] as List) TradeChip(t as String)]),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          // Large overall rating + parameter-wise breakdown
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(children: [
                Row(children: [
                  StarBadge(b['overall'] as num, big: true),
                  const SizedBox(width: 8),
                  Text(l.ratingFromJobs(b['count'] as int), style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  SpeakButton(
                      text: l.ratingSpeech((b['overall'] as num).toStringAsFixed(1), (b['quality'] as num).toStringAsFixed(1),
                          (b['timeliness'] as num).toStringAsFixed(1), (b['behaviour'] as num).toStringAsFixed(1), (b['value_for_money'] as num).toStringAsFixed(1)),
                      lang: state.language ?? 'hi'),
                ]),
                const SizedBox(height: 8),
                RatingBars(breakdown: b),
              ]),
            ),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final badge in badges)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InfoBanner(icon: Icons.workspace_premium_rounded, color: const Color(0xFFB45309),
                    text: badgeLabel(l, badge, b['overall'] as num, b['count'] as int)),
              ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LabourCardScreen(state: state))),
            style: FilledButton.styleFrom(backgroundColor: BC.ink),
            icon: const Icon(Icons.badge_rounded),
            label: Text(l.myLabourCard),
          ),
          const SizedBox(height: 16),
          KycStatusCard(state: state, kyc: kyc, onChanged: reload),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(l.workHistory, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: history.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (ctx, i) {
                  final h = history[i];
                  return SizedBox(
                    width: 180,
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        AppImage(h['photo'] as String?, height: 100, width: 180),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            StarBadge(h['rating'] as num),
                            Text('${h['locality']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            if (h['comment'] != null)
                              Text('“${h['comment']}”', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, fontSize: 13)),
                          ]),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 20),
          Card(
            child: SwitchListTile(
              value: p['is_online'] == true,
              onChanged: (v) async {
                await state.api.setOnline(v);
                await reload();
              },
              title: Text(l.availableForWork, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              subtitle: Text(l.availableForWorkSub),
              secondary: Icon(Icons.circle, color: p['is_online'] == true ? BC.money : BC.inkFaint, size: 18),
            ),
          ),
          const SizedBox(height: 12),
          ...settingsTiles(context, state),
        ]);
      },
    );
  }
}

String initials(String name) =>
    name.trim().isEmpty ? '?' : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w.characters.first).join().toUpperCase();

String badgeLabel(L l, String code, num rating, int count) {
  if (code == 'fast_responder') return l.badgeFast;
  final parts = code.split('_');
  final trade = tradeLabel(l, parts.length > 1 ? parts[1] : 'helper');
  return parts.first == 'trusted' ? l.badgeTrusted(trade, rating.toStringAsFixed(1), count) : l.badgeRising(trade);
}
