import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';
import '../../widgets/trust_widgets.dart';
import '../common/chat.dart';
import 'customer_home.dart' show customerRoute, bookingStatus;
import 'payment.dart';

/// Contractor view of ONE team job: applicants per trade (accept several, up to the headcount),
/// one checkout for the whole team, then the roster with today's attendance, days worked, amount due
/// and "Rate & pay" per worker (days actually worked are paid, unworked days are refunded).
class TeamJobScreen extends StatefulWidget {
  const TeamJobScreen({super.key, required this.state, required this.jobId});
  final AppState state;
  final String jobId;
  @override
  State<TeamJobScreen> createState() => _TeamJobScreenState();
}

class _TeamJobScreenState extends State<TeamJobScreen> {
  Json? _job;
  Object? _error;
  bool _busy = false;
  Timer? _timer;

  AppState get _s => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final j = await _s.api.customerJob(widget.jobId);
      if (mounted) {
        setState(() {
          _job = j;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e);
    }
  }

  Future<void> _accept(Json bid) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _s.api.acceptBid(widget.jobId, bid['id'] as String);
      HapticFeedback.mediumImpact();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _payTeam(Json team) async {
    final l = L.of(context);
    final due = team['payment_due_inr'] as num;
    final n = team['payment_due_count'] as int;
    final fee = (_job?['fee_inr'] as num? ?? 30) * n;
    await Navigator.of(context).push(customerRoute<void>(
      builder: (_) => PaymentScreen(state: _s, jobId: widget.jobId, workerName: l.teamOfN(n), price: due - fee, fee: fee),
    ));
    await _load();
  }

  Future<void> _settle(Json w) async {
    final done = await Navigator.of(context).push<bool>(customerRoute<bool>(
      builder: (_) => SettleWorkerScreen(state: _s, jobId: widget.jobId, row: w),
    ));
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final job = _job;
    return Scaffold(
      appBar: AppBar(title: Text(l.teamSiteTitle)),
      body: job == null
          ? (_error != null
              ? Center(child: OutlinedButton(onPressed: _load, child: Text(l.retry)))
              : const SkeletonList(count: 3, itemHeight: 140))
          : RefreshIndicator(color: BC.brand, onRefresh: _load, child: _body(l, job)),
    );
  }

  Widget _body(L l, Json job) {
    final team = (job['team'] as Json?) ?? const <String, dynamic>{};
    final summary = (team['summary'] as Json?) ?? const <String, dynamic>{};
    final workers = ((team['workers'] as List?) ?? const []).cast<Json>();
    final lines = ((summary['items'] as List?) ?? const []).cast<Json>();
    final bids = (job['bids'] as List).cast<Json>().where((b) => b['status'] == 'pending').toList();
    final dueN = (team['payment_due_count'] as int?) ?? 0;
    final status = job['status'] as String;
    final (label, fg, bg, icon) = bookingStatus(l, job);
    final filled = (summary['filled'] as int?) ?? 0, total = (summary['headcount'] as int?) ?? 0;
    final open = status == 'open' || status == 'bidding' || status == 'assigned' || status == 'in_progress';
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      AppCard(
        shadow: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(l.teamFilled(filled, total), style: context.tt.headlineSmall)),
            const SizedBox(width: 8),
            Flexible(child: StatusPill(label: label, color: fg, bg: bg, icon: icon)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: total == 0 ? 0 : filled / total, minHeight: 8, backgroundColor: BC.line, color: BC.money),
          ),
          const SizedBox(height: 10),
          Text('📍 ${job['address'] ?? job['locality']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
          const SizedBox(height: 4),
          ScheduleLine(iso: job['scheduled_for'] as String?, slot: job['time_slot'] as String?),
          if (filled > 0) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.how_to_reg_rounded, size: 16, color: BC.money),
              const SizedBox(width: 4),
              Expanded(child: Text(l.teamPresentCount((summary['present_today'] as int?) ?? 0, filled), style: const TextStyle(fontWeight: FontWeight.w600, color: BC.money))),
            ]),
          ],
        ]),
      ),
      if (dueN > 0) ...[
        const SizedBox(height: 12),
        InfoBanner(icon: Icons.account_balance_wallet_rounded, color: BC.brandDark, text: l.teamPayBanner(dueN)),
        const SizedBox(height: 10),
        PrimaryButton(
          big: true,
          icon: Icons.lock_rounded,
          onPressed: () => _payTeam(team),
          label: l.teamPayAll(inr(team['payment_due_inr'] as num)),
        ),
      ],
      // ------------------------------------------------ applicants, per trade
      if (open) ...[
        const SizedBox(height: 8),
        for (final line in lines) ...[
          SectionHeader(
            '${tradeLabel(l, line['trade'] as String)} · ${l.teamFilled(line['filled'] as int, line['headcount'] as int)}',
            padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
          ),
          ..._applicants(l, line, bids),
        ],
      ],
      // ------------------------------------------------ roster
      if (workers.isNotEmpty) ...[
        SectionHeader(l.teamRoster, padding: const EdgeInsets.fromLTRB(2, 20, 2, 6)),
        for (final w in workers) ...[
          _RosterTile(row: w, onSettle: () => _settle(w), onChat: () {
            final wk = w['worker'] as Json;
            openChat(context, _s, jobId: widget.jobId, withUser: wk['id'] as String, title: wk['name'] as String);
          }),
          const SizedBox(height: 10),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, size: 16, color: BC.inkSoft),
            const SizedBox(width: 6),
            Expanded(child: Text(l.teamRefundNote, style: BC.subtle)),
          ]),
        ),
      ],
    ]);
  }

  List<Widget> _applicants(L l, Json line, List<Json> bids) {
    final mine = bids.where((b) => b['trade'] == line['trade']).toList();
    final full = (line['filled'] as int) >= (line['headcount'] as int);
    if (mine.isEmpty) {
      return [Padding(padding: const EdgeInsets.fromLTRB(2, 2, 2, 6), child: Text(full ? l.teamLineFull : l.teamNoApplicants, style: BC.subtle))];
    }
    return [
      for (final b in mine) ...[
        _ApplicantTile(bid: b, offered: line['daily_wage_inr'] as num, canAccept: !full && !_busy, onAccept: () => _accept(b)),
        const SizedBox(height: 8),
      ],
    ];
  }
}

class _ApplicantTile extends StatelessWidget {
  const _ApplicantTile({required this.bid, required this.offered, required this.canAccept, required this.onAccept});
  final Json bid;
  final num offered;
  final bool canAccept;
  final VoidCallback onAccept;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = bid['worker'] as Json;
    final wage = bid['daily_wage_inr'] as num;
    final days = (bid['days'] as num?) ?? 1;
    final minWage = bid['min_wage'] as num?;
    final below = minWage != null && wage < minWage;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 22, backgroundColor: BC.brandSoft, child: Text(_initials(w['name'] as String), style: const TextStyle(fontWeight: FontWeight.w700, color: BC.brandDark))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(w['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              StarBadge((w['rating'] as num).toDouble(), count: (w['rating_count'] as num?)?.toInt()),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(l.perDay(inr(wage)), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
            MoneyText(wage * days, size: MoneySize.s, color: BC.inkSoft),
          ]),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          if (wage == offered) Flexible(child: StatusPill(label: l.teamJoinedAtOffer, color: BC.money, bg: BC.moneySoft, icon: Icons.handshake_rounded))
          else Flexible(child: StatusPill(label: l.teamOwnRate, color: BC.pendingInk, bg: BC.pendingSoft, icon: Icons.request_quote_rounded)),
          if (below) ...[const SizedBox(width: 6), Flexible(child: StatusPill(label: l.fairBadgeBelow, color: BC.danger, bg: const Color(0xFFFEE2E2)))],
          const Spacer(),
          SizedBox(
            height: BC.btnXs,
            child: FilledButton(
              onPressed: canAccept ? onAccept : null,
              style: FilledButton.styleFrom(minimumSize: const Size(96, BC.btnXs), padding: const EdgeInsets.symmetric(horizontal: 16)),
              child: BtnLabel(l.teamAccept),
            ),
          ),
        ]),
      ]),
    );
  }
}

String _initials(String name) {
  final p = name.trim().split(RegExp(r'\s+'));
  return (p.first.isEmpty ? '?' : p.first[0]) + (p.length > 1 ? p.last[0] : '');
}

/// One person on the roster: attendance today, days worked, amount due, payment state, Rate & pay.
class _RosterTile extends StatelessWidget {
  const _RosterTile({required this.row, required this.onSettle, required this.onChat});
  final Json row;
  final VoidCallback onSettle, onChat;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = row['worker'] as Json;
    final pay = row['payment'] as Json?;
    final state = pay?['escrow_state'] as String? ?? 'created';
    final trade = row['trade'] as String? ?? 'helper';
    final settled = row['settled'] == true;
    final present = row['present_today'] == true;
    final worked = row['days_worked'] as int, planned = row['days_planned'] as int;
    Widget pill;
    if (settled) {
      pill = StatusPill(label: l.teamSettled, color: BC.money, bg: BC.moneySoft, icon: Icons.check_circle_rounded);
    } else if (state == 'created') {
      pill = StatusPill(label: l.teamAwaitingPayment, color: BC.pendingInk, bg: BC.pendingSoft, icon: Icons.hourglass_top_rounded);
    } else if (present) {
      pill = StatusPill(label: l.teamPresentToday, color: BC.money, bg: BC.moneySoft, icon: Icons.how_to_reg_rounded);
    } else {
      pill = StatusPill(label: l.teamNotInYet, color: BC.closed, bg: BC.closedSoft, icon: Icons.person_off_outlined);
    }
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBadge(TradeStyle.of(trade).icon, color: TradeStyle.of(trade).color, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(w['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                if (w['police_verified'] == true) const Padding(padding: EdgeInsets.only(left: 4), child: PoliceBadge(size: 16)),
              ]),
              Text('${tradeLabel(l, trade)} · ${l.perDay(inr(row['daily_wage_inr'] as num))}', maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.subtle),
            ]),
          ),
          IconButton(onPressed: onChat, icon: const Icon(Icons.chat_bubble_outline_rounded)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          pill,
          Text(l.teamDaysWorked(worked, planned), style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
          Text(settled && pay != null ? l.teamPaidOut(inr(pay['worker_payout_inr'] as num)) : l.teamDue(inr(row['amount_due_inr'] as num)),
              style: const TextStyle(fontWeight: FontWeight.w700, color: BC.money, fontFeatures: BC.tabular)),
        ]),
        // One start code per worker per day: the contractor tells it to him when he arrives on site.
        if (!settled && state == 'held' && row['start_code'] is Map && (row['start_code'] as Map)['verified_today'] != true) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: BC.brandSoft, borderRadius: BorderRadius.circular(BC.rSm)),
            child: Row(children: [
              const Icon(Icons.password_rounded, color: BC.brandDark),
              const SizedBox(width: 8),
              Expanded(child: Text(l.teamCodeToday('${(row['start_code'] as Map)['code']}'), key: const ValueKey('teamCode'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: BC.brandDark, fontFeatures: BC.tabular))),
            ]),
          ),
        ] else if (!settled && state == 'held' && row['start_code'] is Map) ...[
          const SizedBox(height: 6),
          Text(l.teamCodeDone, style: BC.caption),
        ],
        if (settled && pay != null && (pay['refund_inr'] as num) > 0) ...[
          const SizedBox(height: 4),
          Text(l.teamRefundedToYou(inr(pay['refund_inr'] as num)), style: BC.subtle),
        ],
        if (!settled && state == 'held') ...[
          const SizedBox(height: 10),
          SecondaryButton(onPressed: onSettle, icon: Icons.star_rounded, label: l.teamRateAndPay, compact: true),
        ],
      ]),
    );
  }
}

/// Rate one team member (mandatory, 4 parameters) and release his pay for the days he worked.
class SettleWorkerScreen extends StatefulWidget {
  const SettleWorkerScreen({super.key, required this.state, required this.jobId, required this.row});
  final AppState state;
  final String jobId;
  final Json row;
  @override
  State<SettleWorkerScreen> createState() => _SettleWorkerScreenState();
}

class _SettleWorkerScreenState extends State<SettleWorkerScreen> {
  final _v = {'quality': 0, 'timeliness': 0, 'behaviour': 0, 'value_for_money': 0};
  bool _busy = false;

  double get _overall => _v.values.every((x) => x > 0) ? _v.values.reduce((a, b) => a + b) / 4 : 0;

  Future<void> _submit() async {
    final l = L.of(context);
    final name = (widget.row['worker'] as Json)['name'] as String;
    setState(() => _busy = true);
    try {
      final r = await widget.state.api.settleTeamWorker(widget.jobId, widget.row['assignment_id'] as String, {..._v, 'comment': null});
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.payments_rounded, color: BC.money, size: 56),
          title: Text(l.paymentReleased, textAlign: TextAlign.center),
          content: Text(l.teamSettledSub(name, inr(r['payout_inr'] as num), inr(r['refund_inr'] as num)), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = widget.row['worker'] as Json;
    final wage = widget.row['daily_wage_inr'] as num;
    final worked = widget.row['days_worked'] as int, planned = widget.row['days_planned'] as int;
    final labels = {
      'quality': (l.rateQuality, Icons.construction_rounded),
      'timeliness': (l.rateTimeliness, Icons.schedule_rounded),
      'behaviour': (l.rateBehaviour, Icons.sentiment_satisfied_rounded),
      'value_for_money': (l.rateValue, Icons.currency_rupee_rounded),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l.rateName(w['name'] as String))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(BC.rLg)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.teamDaysWorked(worked, planned), style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: MoneyText(wage * worked, size: MoneySize.xl, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(worked == 0 ? l.teamNoShowRefund : l.teamUnworkedRefund(inr(wage * (planned - worked))), style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ]),
        ),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.lock_clock_rounded, color: BC.pendingInk, text: l.teamRatingRequired),
        const SizedBox(height: 16),
        for (final e in labels.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(e.value.$2, color: BC.inkSoft),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e.value.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 6),
                StarInput(value: _v[e.key]!, onChanged: (x) => setState(() => _v[e.key] = x), size: 40),
              ]),
            ),
          ),
        const SizedBox(height: 6),
        PrimaryButton(
          busy: _busy,
          onPressed: _overall == 0 ? null : _submit,
          icon: Icons.lock_open_rounded,
          label: l.teamRateAndPay,
        ),
      ]),
    );
  }
}
