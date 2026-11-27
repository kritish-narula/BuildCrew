import 'package:flutter/material.dart';

import '../common/notifications.dart';
import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/job_progress.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';
import '../../widgets/trust_widgets.dart';
import '../worker/worker_shell.dart' show initials;
import 'contractor.dart';

/// Caps primary/secondary buttons at 52dp for every customer screen, whatever the app theme
/// says (merges into the theme's own style, so colours and shapes are untouched).
class CompactButtons extends StatelessWidget {
  const CompactButtons({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const h = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(52)));
    return Theme(
      data: t.copyWith(
        filledButtonTheme: FilledButtonThemeData(style: (t.filledButtonTheme.style ?? const ButtonStyle()).merge(h)),
        outlinedButtonTheme: OutlinedButtonThemeData(style: (t.outlinedButtonTheme.style ?? const ButtonStyle()).merge(h)),
      ),
      child: child,
    );
  }
}

/// Route for every customer screen: same as MaterialPageRoute, with [CompactButtons] applied.
MaterialPageRoute<T> customerRoute<T>({required WidgetBuilder builder}) =>
    MaterialPageRoute<T>(builder: (c) => CompactButtons(child: builder(c)));

/// Where a booking lives in the Bookings tabs.
enum BookingGroup { open, ongoing, past }

/// Open = still collecting quotes. Ongoing = anything with a worker that is not finished, plus
/// finished jobs still waiting for the customer's rating (money is held until then).
/// Past = paid/completed and cancelled.
BookingGroup bookingGroup(Json j) {
  if (j['needs_rating'] == true) return BookingGroup.ongoing;
  return switch (j['status']) {
    'open' || 'bidding' => BookingGroup.open,
    'assigned' || 'in_progress' || 'disputed' => BookingGroup.ongoing,
    _ => BookingGroup.past,
  };
}

Json? _assignmentOf(Json j) => (j['detail'] as Json?)?['assignment'] as Json?;

/// Pill (label, colour, background, icon) for a booking row.
(String, Color, Color, IconData) bookingStatus(L l, Json j) {
  if (j['needs_rating'] == true) return (l.statusCompleted, BC.brandDark, BC.brandSoft, Icons.star_rounded);
  return switch (j['status']) {
    'open' => (l.statusOpen, BC.info, BC.infoSoft, Icons.campaign_rounded),
    'bidding' => (l.statusBidding, const Color(0xFF92400E), BC.pendingSoft, Icons.hourglass_top_rounded),
    'assigned' => (l.statusAssigned, BC.money, BC.moneySoft, Icons.handshake_rounded),
    'in_progress' => (l.statusInProgress, BC.info, BC.infoSoft, Icons.construction_rounded),
    'completed' => (l.statusPaid, BC.money, BC.moneySoft, Icons.check_circle_rounded),
    'disputed' => (l.statusDisputed, BC.danger, const Color(0xFFFEE2E2), Icons.gavel_rounded),
    _ => (l.statusCancelled, BC.closed, BC.closedSoft, Icons.block_rounded),
  };
}

/// The one thing the customer should do next on this booking (null = nothing to do).
(String, Color)? bookingNextAction(L l, Json j) {
  final status = j['status'] as String? ?? '';
  final name = j['worker_name'] as String? ?? '';
  if (j['kind'] == 'team') {
    // a contractor's team job: pay the team, settle workers, look at applicants
    final team = (j['team'] as Json?) ?? const <String, dynamic>{};
    final filled = (team['filled'] as num?)?.toInt() ?? 0, bids = (j['bid_count'] as num?)?.toInt() ?? 0;
    if (j['payment_state'] == 'created' && ((j['payment_due_inr'] as num?) ?? 0) > 0) return (l.teamPayNow(inr(j['payment_due_inr'] as num)), BC.brandDark);
    if (((j['to_settle'] as num?) ?? 0) > 0) return (l.teamToSettle((j['to_settle'] as num).toInt()), BC.money);
    if (bids > filled && filled < ((team['headcount'] as num?)?.toInt() ?? 0)) return (l.teamApplicants(bids - filled), BC.money);
    return null;
  }
  final a = _assignmentOf(j);
  final tr = a?['tracking'] as Json?;
  if (j['needs_rating'] == true) return (l.rateNow, BC.brandDark);
  if ((status == 'open' || status == 'bidding') && ((j['bid_count'] as num?) ?? 0) > 0) return (l.viewQuotes, BC.money);
  if ((status == 'open' || status == 'bidding') && j['direct_state'] == 'pending') return (l.directWaiting('${j['direct_worker'] ?? ''}'), BC.info);
  if (status == 'assigned' && j['payment_state'] == 'created') return (l.payToConfirm(name), BC.brandDark);
  if (a != null && a['worker_done_at'] != null && (status == 'assigned' || status == 'in_progress')) return (l.workerSaysDone(name), BC.money);
  if (status == 'assigned' && tr != null && tr['arrived'] != true) return (l.workerOnTheWay(name), BC.info);
  return null;
}

/// One booking: trade icons, locality, status, next action, and either the quote count or
/// the hired worker with the agreed price.
class BookingCard extends StatelessWidget {
  const BookingCard({super.key, required this.job, required this.onTap, this.onHireAgain});
  final Json job;
  final VoidCallback onTap;

  /// Past, completed bookings: "Hire again" opens Post a Job prefilled for the same worker.
  final VoidCallback? onHireAgain;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final trades = ((job['trades'] as List?) ?? const []).cast<String>().toSet().toList();
    final status = job['status'] as String? ?? '';
    final (label, fg, bg, icon) = bookingStatus(l, job);
    final next = bookingNextAction(l, job);
    final isOpen = status == 'open' || status == 'bidding';
    final bids = (job['bid_count'] as num?)?.toInt() ?? 0;
    final worker = job['worker_name'] as String?;
    final price = _assignmentOf(job)?['price_inr'] as num?;

    final isTeam = job['kind'] == 'team';
    final team = (job['team'] as Json?) ?? const <String, dynamic>{};
    final String summary;
    if (isTeam) {
      summary = l.teamFilled((team['filled'] as num?)?.toInt() ?? 0, (team['headcount'] as num?)?.toInt() ?? 0);
    } else if (isOpen) {
      summary = l.workersQuoted(bids);
    } else {
      summary = worker ?? '';
    }
    // Hired + agreed price: "Ramesh · ₹1,200" with the price in the one money style.
    final showPrice = !isTeam && !isOpen && worker != null && price != null;
    final progress = (isTeam || bookingGroup(job) == BookingGroup.past) ? null : jobProgress(l, job);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _TradeIcons(trades: trades),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(trades.map((t) => tradeLabel(l, t)).join(', '),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Row(children: [
                    const Icon(Icons.place_outlined, size: 16, color: BC.inkSoft),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text('${job['locality'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, fontSize: 14)),
                    ),
                  ]),
                  ScheduleLine(iso: job['scheduled_for'] as String?, slot: job['time_slot'] as String?),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              if (job['refix'] == true) ...[
                Flexible(child: StatusPill(label: l.refixBadge, color: BC.info, bg: BC.infoSoft, icon: Icons.build_circle_rounded)),
                const SizedBox(width: 6),
              ],
              Flexible(child: StatusPill(label: label, color: fg, bg: bg, icon: icon)),
              if (summary.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Flexible(
                      child: Text(summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isOpen && bids == 0 ? BC.inkSoft : BC.ink)),
                    ),
                    if (showPrice) ...[const SizedBox(width: 6), MoneyText(price, size: MoneySize.s)],
                  ]),
                ),
              ],
            ]),
            if (progress != null) ...[const SizedBox(height: 10), JobProgressBar(info: progress)],
            if (next != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(color: next.$2.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(child: Text(next.$1, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: next.$2))),
                  Icon(Icons.arrow_forward_rounded, size: 18, color: next.$2),
                ]),
              ),
            ],
            if (onHireAgain != null && status == 'completed' && job['hire_again_worker_id'] != null) ...[
              const SizedBox(height: 10),
              SecondaryButton(compact: true, icon: Icons.replay_circle_filled_rounded, label: l.hireAgain, onPressed: onHireAgain),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Up to three overlapping trade icons (the same icon + colour the worker app uses).
class _TradeIcons extends StatelessWidget {
  const _TradeIcons({required this.trades});
  final List<String> trades;
  @override
  Widget build(BuildContext context) {
    final shown = trades.take(3).toList();
    if (shown.isEmpty) return const SizedBox(width: 48, height: 48);
    return SizedBox(
      width: 48.0 + (shown.length - 1) * 16,
      height: 48,
      child: Stack(children: [
        for (final (i, t) in shown.indexed)
          Positioned(
            left: i * 16.0,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Color.alphaBlend(TradeStyle.of(t).color.withValues(alpha: 0.14), Colors.white),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Icon(TradeStyle.of(t).icon, size: 24, color: TradeStyle.of(t).color),
            ),
          ),
      ]),
    );
  }
}

/// Home tab — one dominant action (Post a Job), one secondary (Browse workers), then the
/// bookings that need the customer right now.
class CustomerHomeTab extends StatelessWidget {
  const CustomerHomeTab({
    super.key,
    required this.state,
    required this.jobs,
    required this.failed,
    required this.onReload,
    required this.onOpenJob,
    required this.onPost,
    required this.onBrowse,
    required this.onSeeBookings,
    this.onPostTeam,
    this.onAddBusiness,
    this.onHireAgain,
  });
  /// "Hire again" with a favourite worker (worker id): opens Post a Job prefilled, offered to him first.
  final ValueChanged<String>? onHireAgain;
  /// Contractors only: opens the team-job posting flow and switches the home to "sites".
  final VoidCallback? onPostTeam, onAddBusiness;
  final AppState state;
  final List<Json>? jobs;
  final bool failed;
  final Future<void> Function() onReload;
  final ValueChanged<String> onOpenJob;
  final VoidCallback onPost, onBrowse, onSeeBookings;

  List<Widget> _attention(BuildContext context, L l, List<Json> all) {
    final out = <Widget>[];
    for (final j in all.where((j) => j['kind'] != 'team')) {
      final status = j['status'] as String? ?? '';
      final name = j['worker_name'] as String? ?? '';
      final a = _assignmentOf(j);
      final tr = a?['tracking'] as Json?;
      final id = j['id'] as String;
      String? text, action;
      IconData icon = Icons.info_outline_rounded;
      Color color = BC.info;
      if (j['needs_rating'] == true) {
        text = l.rateWorkerBanner(name);
        action = l.rateNow;
        icon = Icons.star_rounded;
        color = BC.brandDark;
      } else if (status == 'assigned' && j['payment_state'] == 'created') {
        text = l.payToConfirm(name);
        action = l.payNow;
        icon = Icons.account_balance_wallet_rounded;
        color = BC.brandDark;
      } else if (a != null && a['worker_done_at'] != null && (status == 'assigned' || status == 'in_progress')) {
        text = l.workerSaysDone(name);
        action = l.workIsDone;
        icon = Icons.task_alt_rounded;
        color = BC.money;
      } else if (status == 'assigned' && tr != null && tr['arrived'] != true) {
        text = l.workerOnTheWay(name);
        action = l.trackWorker(name);
        icon = Icons.two_wheeler_rounded;
        color = BC.info;
      } else if ((status == 'open' || status == 'bidding') && ((j['bid_count'] as num?) ?? 0) > 0) {
        text = l.workersQuoted((j['bid_count'] as num).toInt());
        action = l.viewQuotes;
        icon = Icons.request_quote_rounded;
        color = BC.money;
      }
      if (text != null) {
        out.add(_ActionCard(icon: icon, color: color, text: text, action: action, onTap: () => onOpenJob(id)));
        out.add(const SizedBox(height: 10));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final name = state.user?.name?.split(' ').first ?? '';
    final all = jobs;
    final attention = all == null ? <Widget>[] : _attention(context, l, all);
    final contractor = onPostTeam != null;
    final org = state.user?.orgName ?? '';
    final sites = (all ?? const <Json>[]).where((j) => isTeamJob(j) && isActiveSite(j)).toList();
    final hasJobs = all != null && all.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(contractor && org.isNotEmpty ? org : (name.isEmpty ? l.appName : l.hello(name)), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [NotificationBell(state: state)],
      ),
      body: RefreshIndicator(
        color: BC.brand,
        onRefresh: onReload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // 1. WHAT DO I NEED TO DO NOW? (only when there is something: waiting for payment, work to check, quotes to compare...)
            if (all == null && failed)
              EmptyState(icon: Icons.cloud_off_rounded, text: l.errorNetwork, actions: [PrimaryButton(expand: false, icon: Icons.refresh_rounded, label: l.retry, onPressed: onReload)])
            else if (all == null)
              const SkeletonList(count: 2, itemHeight: 76, padding: EdgeInsets.only(bottom: 8), shrink: true)
            else if (attention.isNotEmpty) ...[
              SectionHeader(l.attentionTitle, padding: const EdgeInsets.fromLTRB(2, 0, 2, 8)),
              ...attention,
              const SizedBox(height: 8),
            ] else if (hasJobs) ...[
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: BC.moneySoft, borderRadius: BorderRadius.circular(BC.r)),
                child: Row(children: [
                  const Icon(Icons.check_circle_rounded, color: BC.money),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l.allCaughtUp, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: BC.money))),
                ]),
              ),
            ],
            if (contractor && org.isEmpty && onAddBusiness != null) ...[
              InfoBanner(icon: Icons.business_rounded, color: BC.info, text: l.bizNameBanner, action: l.bizNameAdd, onTap: onAddBusiness),
              const SizedBox(height: 16),
            ],
            // 2. THEN: START SOMETHING NEW
            if (contractor) _PostHero(onTap: onPostTeam!, team: true) else _PostHero(onTap: onPost),
            const SizedBox(height: 12),
            if (contractor) ...[
              SecondaryButton(onPressed: onPost, icon: Icons.add_task_rounded, label: l.postSingleJob),
              const SizedBox(height: 12),
            ],
            SecondaryButton(onPressed: onBrowse, icon: Icons.groups_rounded, label: l.browseWorkers),
            if (onHireAgain != null) YourWorkersRow(state: state, jobs: jobs, onHireAgain: onHireAgain!),
            if (contractor && all != null) ...[
              const SizedBox(height: 20),
              SectionHeader(l.teamSitesTitle, padding: const EdgeInsets.fromLTRB(2, 0, 2, 8)),
              if (sites.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
                  child: Text(l.teamNoSites, style: const TextStyle(fontSize: 15, color: BC.inkSoft)),
                )
              else
                for (final j in sites) ...[TeamSiteCard(job: j, onTap: () => onOpenJob(j['id'] as String)), const SizedBox(height: 12)],
            ],
            if (hasJobs) ...[
              const SizedBox(height: 8),
              TextButton.icon(onPressed: onSeeBookings, icon: const Icon(Icons.assignment_outlined), label: Text(l.seeAllBookings)),
            ],
          ],
        ),
      ),
    );
  }
}

/// One thing that needs the customer NOW: big icon, one sentence, one coloured action. The whole card is the button.
class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.color, required this.text, required this.onTap, this.action});
  final IconData icon;
  final Color color;
  final String text;
  final String? action;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          onTap: onTap,
          shadow: true,
          borderColor: color.withValues(alpha: 0.45),
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBadge(icon, color: color, size: 48, solid: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall),
                if (action != null)
                  Text(action!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.labelLarge!.copyWith(color: color, fontWeight: FontWeight.w800)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: color),
          ]),
        ),
      );
}

class _PostHero extends StatelessWidget {
  const _PostHero({required this.onTap, this.team = false});
  final VoidCallback onTap;
  final bool team;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Material(
      color: BC.brand,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(team ? l.postTeamJob : l.postJob, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(team ? l.postTeamJobSub : l.postJobSub, style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 15)),
                const SizedBox(height: 14),
                Row(children: [
                  for (final ic in team
                      ? [Icons.groups_rounded, Icons.calendar_month_rounded, Icons.currency_rupee_rounded]
                      : [Icons.photo_camera_rounded, Icons.mic_rounded, Icons.currency_rupee_rounded])
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
                      child: Icon(ic, color: Colors.white, size: 20),
                    ),
                ]),
              ]),
            ),
            const SizedBox(width: 12),
            Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: const Icon(Icons.add_rounded, color: BC.brand, size: 38),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Bookings tab: Open · Ongoing · Past.
class CustomerBookingsTab extends StatelessWidget {
  const CustomerBookingsTab({
    super.key,
    required this.jobs,
    required this.failed,
    required this.onReload,
    required this.onOpenJob,
    required this.onPost,
    this.onHireAgain,
  });
  final List<Json>? jobs;
  final bool failed;
  final Future<void> Function() onReload;
  final ValueChanged<String> onOpenJob;
  final VoidCallback onPost;
  final ValueChanged<Json>? onHireAgain; // job -> prefilled Post a Job for the worker who did it

  Widget _list(BuildContext context, L l, BookingGroup g, String empty) {
    final all = jobs;
    if (all == null) {
      return failed
          ? EmptyState(icon: Icons.cloud_off_rounded, text: l.errorNetwork, actions: [PrimaryButton(expand: false, icon: Icons.refresh_rounded, label: l.retry, onPressed: onReload)])
          : const SkeletonList(count: 4);
    }
    final items = all.where((j) => bookingGroup(j) == g).toList();
    return RefreshIndicator(
      color: BC.brand,
      onRefresh: onReload,
      child: items.isEmpty
          // Every empty list says what to do next.
          ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
              EmptyState(
                icon: Icons.inbox_outlined,
                text: empty,
                actions: [PrimaryButton(expand: false, icon: Icons.add_rounded, label: l.postJob, onPressed: onPost)],
              ),
            ])
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => BookingCard(
                job: items[i],
                onTap: () => onOpenJob(items[i]['id'] as String),
                onHireAgain: onHireAgain == null ? null : () => onHireAgain!(items[i]),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    String tabLabel(String text, BookingGroup g) {
      final n = jobs?.where((j) => bookingGroup(j) == g).length ?? 0;
      return n > 0 ? '$text ($n)' : text;
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.bookingsTitle),
          bottom: TabBar(
            labelColor: BC.brandDark,
            unselectedLabelColor: BC.inkSoft,
            indicatorColor: BC.brand,
            labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            tabs: [
              Tab(text: tabLabel(l.bookingsOpen, BookingGroup.open)),
              Tab(text: tabLabel(l.bookingsOngoing, BookingGroup.ongoing)),
              Tab(text: tabLabel(l.bookingsPast, BookingGroup.past)),
            ],
          ),
        ),
        body: TabBarView(children: [
          _list(context, l, BookingGroup.open, l.bookingsEmptyOpen),
          _list(context, l, BookingGroup.ongoing, l.bookingsEmptyOngoing),
          _list(context, l, BookingGroup.past, l.bookingsEmptyPast),
        ]),
      ),
    );
  }
}


/// Home: "Your workers" - people this customer rated 4 or more, each with a one-tap "Hire again".
class YourWorkersRow extends StatefulWidget {
  const YourWorkersRow({super.key, required this.state, required this.jobs, required this.onHireAgain});
  final AppState state;
  final List<Json>? jobs;
  final ValueChanged<String> onHireAgain;
  @override
  State<YourWorkersRow> createState() => _YourWorkersRowState();
}

class _YourWorkersRowState extends State<YourWorkersRow> {
  List<Json> _workers = const [];
  String _sig = '';

  /// Changes when a job gets rated / completed (the list of favourites can change), not on every 4 s refresh.
  String get _signature =>
      '${widget.state.user?.id}:${(widget.jobs ?? const <Json>[]).where((j) => j['status'] == 'completed' && j['needs_rating'] != true).length}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(YourWorkersRow old) {
    super.didUpdateWidget(old);
    if (_signature != _sig) _load();
  }

  Future<void> _load() async {
    _sig = _signature;
    try {
      final w = await widget.state.api.favourites();
      if (mounted) setState(() => _workers = w);
    } catch (_) {/* the row is a bonus: hidden when it cannot load */}
  }

  @override
  Widget build(BuildContext context) {
    if (_workers.isEmpty) return const SizedBox.shrink();
    final l = L.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 20),
      SectionHeader(l.yourWorkers, padding: const EdgeInsets.fromLTRB(2, 0, 2, 8)),
      SizedBox(
        height: 196,
        child: ListView.separated(
          key: const ValueKey('yourWorkers'),
          scrollDirection: Axis.horizontal,
          itemCount: _workers.length.clamp(0, 10),
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (ctx, i) {
            final w = _workers[i];
            return SizedBox(
              width: 156,
              child: AppCard(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  CircleAvatar(radius: 24, backgroundColor: BC.brand, child: Text(initials(w['name'] as String), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Flexible(child: Text(w['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: ctx.tt.titleSmall)),
                    if (w['police_verified'] == true) const Padding(padding: EdgeInsets.only(left: 4), child: PoliceBadge(size: 16)),
                  ]),
                  const SizedBox(height: 2),
                  Text((w['trades'] as List).map((t) => tradeLabel(l, t as String)).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.caption),
                  const SizedBox(height: 4),
                  StarBadge(w['rating'] as num),
                  const Spacer(),
                  SecondaryButton(compact: true, icon: Icons.replay_circle_filled_rounded, label: l.hireAgain, onPressed: () => widget.onHireAgain(w['id'] as String)),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
