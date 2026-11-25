import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';

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
  final a = _assignmentOf(j);
  final tr = a?['tracking'] as Json?;
  if (j['needs_rating'] == true) return (l.rateNow, BC.brandDark);
  if ((status == 'open' || status == 'bidding') && ((j['bid_count'] as num?) ?? 0) > 0) return (l.viewQuotes, BC.money);
  if (status == 'assigned' && j['payment_state'] == 'created') return (l.payToConfirm(name), BC.brandDark);
  if (a != null && a['worker_done_at'] != null && (status == 'assigned' || status == 'in_progress')) return (l.workerSaysDone(name), BC.money);
  if (status == 'assigned' && tr != null && tr['arrived'] != true) return (l.workerOnTheWay(name), BC.info);
  return null;
}

/// One booking: trade icons, locality, status, next action, and either the quote count or
/// the hired worker with the agreed price.
class BookingCard extends StatelessWidget {
  const BookingCard({super.key, required this.job, required this.onTap});
  final Json job;
  final VoidCallback onTap;

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

    final String summary;
    if (isOpen) {
      summary = l.workersQuoted(bids);
    } else if (worker != null) {
      summary = price == null ? worker : '$worker · ${inr(price)}';
    } else {
      summary = '';
    }

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
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Flexible(child: StatusPill(label: label, color: fg, bg: bg, icon: icon)),
              if (summary.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isOpen && bids == 0 ? BC.inkSoft : BC.ink)),
                ),
              ],
            ]),
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
  });
  final AppState state;
  final List<Json>? jobs;
  final bool failed;
  final Future<void> Function() onReload;
  final ValueChanged<String> onOpenJob;
  final VoidCallback onPost, onBrowse, onSeeBookings;

  List<Widget> _attention(BuildContext context, L l, List<Json> all) {
    final out = <Widget>[];
    for (final j in all) {
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
        out.add(InfoBanner(icon: icon, color: color, text: text, action: action, onTap: () => onOpenJob(id)));
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
    return Scaffold(
      appBar: AppBar(title: Text(name.isEmpty ? l.appName : l.hello(name))),
      body: RefreshIndicator(
        color: BC.brand,
        onRefresh: onReload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _PostHero(onTap: onPost),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onBrowse,
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.groups_rounded),
              label: Text(l.browseWorkers, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 24),
            if (all == null && failed)
              Center(child: OutlinedButton(onPressed: onReload, child: Text(l.retry)))
            else if (all == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: BC.brand)))
            else if (all.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
                child: Text(l.noJobsYet, style: const TextStyle(fontSize: 16, color: BC.inkSoft)),
              )
            else ...[
              Text(l.attentionTitle, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              if (attention.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
                  child: Row(children: [
                    const Icon(Icons.check_circle_outline_rounded, color: BC.money),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l.allCaughtUp, style: const TextStyle(fontSize: 15, color: BC.inkSoft))),
                  ]),
                )
              else
                ...attention,
              const SizedBox(height: 6),
              TextButton(onPressed: onSeeBookings, child: Text(l.seeAllBookings)),
            ],
          ],
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
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.postJob, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(l.postJobSub, style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 15)),
                const SizedBox(height: 14),
                Row(children: [
                  for (final ic in [Icons.photo_camera_rounded, Icons.mic_rounded, Icons.currency_rupee_rounded])
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
  });
  final List<Json>? jobs;
  final bool failed;
  final Future<void> Function() onReload;
  final ValueChanged<String> onOpenJob;
  final VoidCallback onPost;

  Widget _list(BuildContext context, L l, BookingGroup g, String empty, {bool withPost = false}) {
    final all = jobs;
    if (all == null) {
      return failed
          ? Center(child: OutlinedButton(onPressed: onReload, child: Text(l.retry)))
          : const Center(child: CircularProgressIndicator(color: BC.brand));
    }
    final items = all.where((j) => bookingGroup(j) == g).toList();
    return RefreshIndicator(
      color: BC.brand,
      onRefresh: onReload,
      child: items.isEmpty
          ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
              EmptyState(icon: Icons.inbox_outlined, text: empty),
              if (withPost)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: FilledButton.icon(
                    onPressed: onPost,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    icon: const Icon(Icons.add_rounded),
                    label: BtnLabel(l.postJob),
                  ),
                ),
            ])
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => BookingCard(job: items[i], onTap: () => onOpenJob(items[i]['id'] as String)),
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
          _list(context, l, BookingGroup.open, l.bookingsEmptyOpen, withPost: true),
          _list(context, l, BookingGroup.ongoing, l.bookingsEmptyOngoing),
          _list(context, l, BookingGroup.past, l.bookingsEmptyPast),
        ]),
      ),
    );
  }
}
