import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/location.dart';
import '../../core/outbox.dart';
import '../../core/poller.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../common/chat.dart';
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

/// Fired by the shell's poll / app resume: every visible tab reloads quietly (old data stays on screen).
class _RefreshTick extends ChangeNotifier {
  void fire() => notifyListeners();
}

class _WorkerShellState extends State<WorkerShell> with WidgetsBindingObserver {
  int _tab = 0;
  final _tick = _RefreshTick();
  late final Poller _poller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Outbox.instance.init(widget.state.api);
    // 4 s while the app is in the foreground (paused in the background, immediate refresh on resume).
    _poller = Poller(const Duration(seconds: 4), () async => _tick.fire())..start();
  }

  @override
  void dispose() {
    _poller.dispose();
    _tick.dispose();
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
            JobsTab(state: widget.state, refresh: _tick),
            BidsTab(state: widget.state, active: _tab == 1, refresh: _tick),
            EarningsTab(state: widget.state, active: _tab == 2, refresh: _tick),
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
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: StatusPill(label: L.of(context).pendingSync(Outbox.instance.pending), color: BC.pendingInk,
                      bg: BC.pendingSoft, icon: Icons.cloud_upload_outlined),
                ),
              ),
      );
}

// ================================================================== S4 Jobs
DateTime? _lastLocationPush; // the 4 s refresh must not re-send the phone's position every time

class JobsTab extends StatelessWidget {
  const JobsTab({super.key, required this.state, this.refresh});
  final AppState state;
  final Listenable? refresh;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return AsyncList<(List<Json>, List<Json>)>(
      refresh: refresh,
      load: () async {
        // "Near you" must mean near the worker's real position, not a saved home address.
        final stale = _lastLocationPush == null || DateTime.now().difference(_lastLocationPush!) > const Duration(minutes: 1);
        final p = stale ? await LocationService.quiet() : null;
        if (p != null) {
          _lastLocationPush = DateTime.now();
          try {
            await state.api.updateMyLocation(p.latitude, p.longitude);
          } catch (_) {}
        }
        return (await state.api.workerFeed(), await state.api.assignments());
      },
      builder: (ctx, data, reload) {
        final (jobs, work) = data;
        final active = work.where((a) => const ['assigned', 'in_progress', 'disputed'].contains((a['job'] as Json)['status'])).toList();
        final toRate = work.where((a) => (a['job'] as Json)['status'] == 'completed' && (a['ratings'] as Map)['worker_to_customer'] == null).toList();
        final today = [...active, ...toRate];
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
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
                  try {
                    await state.api.updateMyLocation(p.latitude, p.longitude);
                  } catch (_) {}
                  await reload();
                }
              },
            ),
            const SizedBox(height: 16),
          ],
          if (state.user != null && state.user!.kycLevel < 1 && work.isNotEmpty) ...[
            KycNudge(state: state, onDone: reload),
            const SizedBox(height: 16),
          ],
          // "Today's work" first: the job that already pays beats new jobs.
          if (today.isNotEmpty) SectionHeader(l.todaysWork, padding: const EdgeInsets.fromLTRB(2, 0, 2, 8)),
          for (final a in today) ...[
            ActiveWorkCard(a: a, onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AssignmentScreen(state: state, assignmentId: a['id'] as String)));
              await reload();
            }),
            const SizedBox(height: 12),
          ],
          if (today.isNotEmpty) const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 0, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.jobsNear, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.headlineMedium),
                  Text(l.jobsNearSub(jobs.length), maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
                ]),
              ),
              const SizedBox(width: 4),
              ChatInboxButton(state: state),
              SpeakButton(text: '${l.jobsNear}. ${l.jobsNearSub(jobs.length)}', lang: state.language ?? 'hi'),
            ]),
          ),
          if (jobs.isEmpty)
            EmptyState(icon: Icons.search_off_rounded, text: l.noJobsNear)
          else
            for (final j in jobs) ...[
              JobCard(job: j, onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => JobDetailScreen(state: state, jobId: j['id'] as String)));
                await reload();
              }),
              const SizedBox(height: 16),
            ],
        ]);
      },
    );
  }
}

/// Status card for work the worker already won ("Today's work"): one glance, one tap.
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
      'in_progress' when a['rework_open'] == true => (l.reworkCardTitle, Icons.replay_rounded),
      'in_progress' when a['worker_done_at'] != null => (l.waitingCustomerConfirm, Icons.hourglass_bottom_rounded),
      'in_progress' => (l.workInProgress, Icons.construction_rounded),
      'disputed' => (l.statusDisputed, Icons.gavel_rounded),
      _ => (l.rateCustomerCta, Icons.star_rounded),
    };
    return AppCard(
      color: BC.money,
      borderColor: BC.money,
      radius: BC.rMd,
      padding: const EdgeInsets.all(BC.pad),
      shadow: true,
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(16)),
          child: Icon(icon, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge!.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('${job['locality']} · ${inr(a['price_inr'] as num)}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: context.tt.titleSmall!.copyWith(color: Colors.white.withValues(alpha: 0.92), fontWeight: FontWeight.w500, fontFeatures: BC.tabular)),
          ]),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 28),
      ]),
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
    final where = '${job['locality']}${dist != null ? ' · ${l.kmAway(dist.toStringAsFixed(1))}' : ''}';
    return AppCard(
      padding: EdgeInsets.zero,
      shadow: true,
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Photo strip — what the work looks like, before any words.
        SizedBox(
          height: 132,
          child: thumbs.isEmpty
              ? Container(color: BC.closedSoft, alignment: Alignment.center, child: Icon(TradeStyle.of(trades.isEmpty ? '' : trades.first).icon, size: 40, color: BC.inkFaint))
              : Row(children: [
                  for (final (i, url) in thumbs.take(3).indexed) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(child: AppImage(url, height: 132)),
                  ],
                ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(BC.pad, 14, BC.pad, BC.pad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final t in trades) TradeChip(t),
              // Audio badge: a voice note exists + its data cost. Never auto-plays in the feed.
              if (audio != null)
                StatusPill(
                    label: '${mmss((audio['total_seconds'] as num).toInt())} · ${audio['total_kb']} KB',
                    color: BC.brandDark, bg: BC.brandSoft, icon: Icons.volume_up_rounded),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.place_rounded, size: 18, color: BC.inkFaint),
              const SizedBox(width: 6),
              Expanded(child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.schedule_rounded, size: 18, color: BC.inkFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(timeAgo(l, DateTime.parse(job['posted_at'] as String)), maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.subtle),
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(l.workCount(job['work_count'] as int), maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.subtle)),
            ]),
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: Outbox.instance,
              builder: (ctx, _) {
                if (Outbox.instance.hasPendingFor('bid', job['id'] as String)) {
                  return StatusPill(label: l.bidSavedOffline, color: BC.pendingInk, bg: BC.pendingSoft, icon: Icons.cloud_upload_outlined);
                }
                if (job['already_bid'] == true) {
                  return StatusPill(label: '${l.alreadyQuoted} · ${inr(job['my_price_inr'] as num?)}', color: BC.pendingInk,
                      bg: BC.pendingSoft, icon: Icons.hourglass_top_rounded);
                }
                return PrimaryButton(big: true, onPressed: onTap, icon: Icons.currency_rupee_rounded, label: l.quotePrice);
              },
            ),
          ]),
        ),
      ]),
    );
  }
}

// ================================================================== S6 My Bids
class BidsTab extends StatelessWidget {
  const BidsTab({super.key, required this.state, required this.active, this.refresh});
  final Listenable? refresh;
  final AppState state;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (!active) return const SizedBox.shrink(); // load when opened (saves data)
    return AsyncList<List<Json>>(
      refresh: refresh,
      load: state.api.myBids,
      builder: (ctx, bids, reload) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 0, 12),
          child: Text(l.tabBids, style: context.tt.headlineMedium),
        ),
        const PendingChip(),
        if (bids.isEmpty) EmptyState(icon: Icons.receipt_long_rounded, text: l.noBidsYet),
        for (final b in bids) ...[
          _BidRow(state: state, bid: b, onChanged: reload),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }
}

class _BidRow extends StatefulWidget {
  const _BidRow({required this.state, required this.bid, required this.onChanged});
  final AppState state;
  final Json bid;
  final Future<void> Function() onChanged;
  @override
  State<_BidRow> createState() => _BidRowState();
}

class _BidRowState extends State<_BidRow> {
  bool _withdrawing = false;

  Future<void> _withdraw() async {
    if (_withdrawing) return;
    setState(() => _withdrawing = true);
    try {
      await widget.state.api.withdrawBid(widget.bid['id'] as String);
      await widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _withdrawing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final bid = widget.bid;
    final job = bid['job'] as Json;
    final status = bid['status'] as String;
    // Colour alone tells the story: amber waiting, green won, grey not selected.
    final (label, fg, bg, icon) = switch (status) {
      'pending' => (l.bidPending, BC.pendingInk, BC.pendingSoft, Icons.hourglass_top_rounded),
      'accepted' => (l.bidAccepted, BC.money, BC.moneySoft, Icons.check_circle_rounded),
      'withdrawn' => (l.bidWithdrawn, BC.closed, BC.closedSoft, Icons.undo_rounded),
      _ => (l.bidNotSelected, BC.closed, BC.closedSoft, Icons.do_not_disturb_on_rounded),
    };
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () async {
        final aid = bid['assignment_id'] as String?;
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => aid != null ? AssignmentScreen(state: widget.state, assignmentId: aid) : JobDetailScreen(state: widget.state, jobId: job['id'] as String)));
        await widget.onChanged();
      },
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: fg, width: 4))),
        padding: const EdgeInsets.all(BC.pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(12), child: AppImage(job['thumbnail'] as String?, width: 56, height: 56)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(inr(bid['price_inr'] as num), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.displaySmall),
                Text('${(job['trades'] as List).toSet().map((t) => tradeLabel(l, t as String)).join(', ')} · ${job['locality']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Flexible(child: StatusPill(label: label, color: fg, bg: bg, icon: icon)),
            if (status == 'pending') ...[
              const SizedBox(width: 8),
              Flexible(
                child: TextButton(
                  onPressed: _withdrawing ? null : _withdraw,
                  style: TextButton.styleFrom(foregroundColor: BC.danger),
                  child: BtnLabel(l.withdrawBid),
                ),
              ),
            ],
          ]),
          if (status == 'rejected')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l.bidNotSelectedMsg, style: BC.subtle),
            ),
        ]),
      ),
    );
  }
}

// ================================================================== S7 Earnings
class EarningsTab extends StatelessWidget {
  const EarningsTab({super.key, required this.state, required this.active, this.refresh});
  final Listenable? refresh;
  final AppState state;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final lang = state.language ?? 'hi';
    if (!active) return const SizedBox.shrink();
    return AsyncList<Json>(
      refresh: refresh,
      load: state.api.earnings,
      builder: (ctx, e, reload) {
        final kyc = e['kyc'] as Json;
        final available = e['available_inr'] as num;
        final history = (e['history'] as List).cast<Json>();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          // One dominant number.
          Container(
            padding: const EdgeInsets.all(BC.padLg),
            decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(BC.rLg)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(l.availableBalance, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium!.copyWith(color: Colors.white70, fontWeight: FontWeight.w500))),
                SpeakButton(text: l.balanceSpeech(inr(available)), lang: lang, size: 40),
              ]),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(inr(available), maxLines: 1, style: context.tt.displayLarge!.copyWith(color: Colors.white, fontSize: 44)),
              ),
              if ((e['held_inr'] as num) > 0) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.lock_clock_rounded, color: BC.pending, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(l.heldInEscrow(inr(e['held_inr'] as num)), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.labelLarge!.copyWith(color: BC.pending))),
                ]),
              ],
              const SizedBox(height: 20),
              _WithdrawButton(state: state, earnings: e, reload: reload),
            ]),
          ),
          const SizedBox(height: 16),
          if (kyc['nudge_level2'] == true) ...[
            InfoBanner(icon: Icons.verified_user_rounded, color: BC.info, text: l.kycL2Nudge, action: l.addNow, onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel2Screen(state: state)));
              await reload();
            }),
            const SizedBox(height: 16),
          ],
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _MiniStat(label: l.totalEarned, value: inr(e['total_earned_inr'] as num))),
            const SizedBox(width: 12),
            Expanded(child: _MiniStat(label: l.paidToBank, value: inr(e['paid_out_inr'] as num))),
          ]),
          const SizedBox(height: 20),
          SectionHeader(l.paymentHistory),
          if (history.isEmpty) EmptyState(icon: Icons.payments_outlined, text: l.noPaymentsYet),
          for (final h in history)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _HistoryRow(h: h, subtitle: _subtitle(l, h), speech: _speech(l, h), lang: lang),
            ),
        ]);
      },
    );
  }

  static String _subtitle(L l, Json h) {
    final date = (h['date'] as String).substring(0, 10);
    if (h['kind'] == 'payout') return '${l.sentToUpi(h['upi'] as String? ?? '')} · $date';
    final where = '${(h['trades'] as List).map((t) => tradeLabel(l, t as String)).join(', ')} · ${h['locality']}';
    return '${h['state'] == 'held' ? l.waitingForRating : l.received} · $where';
  }

  static String _speech(L l, Json h) => h['kind'] == 'payout'
      ? l.speechPayout(inr(h['amount_inr'] as num))
      : (h['state'] == 'held' ? l.speechHeld(inr(h['amount_inr'] as num)) : l.speechReceived(inr(h['amount_inr'] as num)));
}

/// Withdraw to UPI. Guarded against double taps (a second tap must never pay out twice).
class _WithdrawButton extends StatefulWidget {
  const _WithdrawButton({required this.state, required this.earnings, required this.reload});
  final AppState state;
  final Json earnings;
  final Future<void> Function() reload;
  @override
  State<_WithdrawButton> createState() => _WithdrawButtonState();
}

class _WithdrawButtonState extends State<_WithdrawButton> {
  bool _busy = false;

  Future<void> _withdraw() async {
    if (_busy) return;
    final l = L.of(context);
    final e = widget.earnings;
    final kyc = e['kyc'] as Json;
    setState(() => _busy = true);
    try {
      if (kyc['needs_level1'] == true) {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KycLevel1Screen(state: widget.state)));
        await widget.reload();
        return;
      }
      final r = await widget.state.api.withdraw();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: BC.money, size: 56),
          title: Text(l.withdrawDone(inr(r['amount_inr'] as num)), textAlign: TextAlign.center),
          content: Text(l.withdrawTo(r['upi'] as String), textAlign: TextAlign.center),
          actions: [PrimaryButton(onPressed: () => Navigator.pop(c), label: l.close)],
        ),
      );
      await widget.reload();
    } catch (err) {
      if (mounted) showError(context, err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final e = widget.earnings;
    final available = e['available_inr'] as num;
    return FilledButton(
      onPressed: available <= 0 || _busy ? null : _withdraw,
      style: FilledButton.styleFrom(
        backgroundColor: BC.money,
        minimumSize: const Size.fromHeight(BC.tap),
        disabledBackgroundColor: _busy ? BC.money : Colors.white12,
        disabledForegroundColor: _busy ? Colors.white : Colors.white38,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (_busy)
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        else
          const Icon(Icons.account_balance_rounded, size: 22),
        const SizedBox(width: 8),
        Flexible(child: BtnLabel(e['upi'] == null ? l.withdrawUpi : l.withdrawToUpi(e['upi'] as String))),
      ]),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.h, required this.subtitle, required this.speech, required this.lang});
  final Json h;
  final String subtitle, speech, lang;
  @override
  Widget build(BuildContext context) {
    final payout = h['kind'] == 'payout';
    final held = h['state'] == 'held';
    final color = payout ? BC.info : (held ? BC.pendingInk : BC.money);
    final icon = payout ? Icons.account_balance_rounded : (held ? Icons.lock_clock_rounded : Icons.south_west_rounded);
    return AppCard(
      // Tap a row to hear it read aloud.
      onTap: () => Speaker.instance.say(speech, lang),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        IconBadge(icon, color: color, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(inr(h['amount_inr'] as num), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge!.copyWith(fontFeatures: BC.tabular)),
            Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
          ]),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.volume_up_rounded, color: BC.inkFaint),
      ]),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(BC.pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: context.tt.displaySmall),
          ),
        ]),
      );
}

// ================================================================== S8 Profile
class WorkerProfileTab extends StatefulWidget {
  const WorkerProfileTab({super.key, required this.state, required this.active});
  final AppState state;
  final bool active;
  @override
  State<WorkerProfileTab> createState() => _WorkerProfileTabState();
}

class _WorkerProfileTabState extends State<WorkerProfileTab> {
  bool _toggling = false;

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (!widget.active) return const SizedBox.shrink();
    return AsyncList<Json>(
      load: state.api.workerProfile,
      builder: (ctx, p, reload) {
        final b = p['breakdown'] as Json;
        final badges = (p['badges'] as List).cast<String>();
        final history = (p['history'] as List).cast<Json>();
        final kyc = p['kyc'] as Json;
        final online = p['is_online'] == true;
        final selfie = p['selfie'] as String?;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          AppCard(
            padding: const EdgeInsets.all(BC.padLg),
            child: Row(children: [
              CircleAvatar(
                radius: 36,
                backgroundColor: BC.brand,
                foregroundImage: selfie != null && selfie.startsWith('http') && AppImage.allowNetwork ? NetworkImage(selfie) : null,
                child: Text(initials(p['name'] as String? ?? ''), style: context.tt.headlineMedium!.copyWith(color: Colors.white)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p['name'] as String? ?? '+91 ${p['phone']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.headlineSmall),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final t in p['trades'] as List) TradeChip(t as String)]),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          // Large overall rating + parameter-wise breakdown
          AppCard(
            padding: const EdgeInsets.all(BC.pad),
            child: Column(children: [
              Row(children: [
                StarBadge(b['overall'] as num, big: true),
                const SizedBox(width: 10),
                Expanded(child: Text(l.ratingFromJobs(b['count'] as int), maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle)),
                SpeakButton(
                    text: l.ratingSpeech((b['overall'] as num).toStringAsFixed(1), (b['quality'] as num).toStringAsFixed(1),
                        (b['timeliness'] as num).toStringAsFixed(1), (b['behaviour'] as num).toStringAsFixed(1), (b['value_for_money'] as num).toStringAsFixed(1)),
                    lang: state.language ?? 'hi'),
              ]),
              const SizedBox(height: 8),
              RatingBars(breakdown: b),
            ]),
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
          PrimaryButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LabourCardScreen(state: state))),
            color: BC.ink,
            icon: Icons.badge_rounded,
            label: l.myLabourCard,
          ),
          const SizedBox(height: 16),
          KycStatusCard(state: state, kyc: kyc, onChanged: reload),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 20),
            SectionHeader(l.workHistory),
            SizedBox(
              height: 224,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: history.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (ctx, i) {
                  final h = history[i];
                  return SizedBox(
                    width: 190,
                    child: AppCard(
                      padding: EdgeInsets.zero,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        AppImage(h['photo'] as String?, height: 100, width: 190),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            StarBadge(h['rating'] as num),
                            Text('${h['locality']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall),
                            if (h['comment'] != null)
                              Text('“${h['comment']}”', maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.caption),
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
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: SwitchListTile(
              value: online,
              onChanged: _toggling
                  ? null
                  : (v) async {
                      setState(() => _toggling = true);
                      try {
                        await state.api.setOnline(v);
                        await reload();
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      } finally {
                        if (mounted) setState(() => _toggling = false);
                      }
                    },
              title: Text(l.availableForWork, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(l.availableForWorkSub, maxLines: 3, overflow: TextOverflow.ellipsis),
              secondary: Icon(Icons.circle, color: online ? BC.money : BC.inkFaint, size: 16),
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
