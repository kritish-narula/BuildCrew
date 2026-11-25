import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/fair_price.dart';
import 'customer_home.dart' show customerRoute;
import '../../widgets/maps.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';
import '../common/chat.dart';
import '../worker/assignment_screen.dart' show EscrowLine;
import '../worker/job_detail.dart' show WorkItemView;
import '../worker/worker_shell.dart' show badgeLabel, initials;
import 'payment.dart';
import 'workers.dart';

/// C3 bid comparison → C4 tracking stepper → C5 mandatory rating → C6 escrow status.
class CustomerJobScreen extends StatefulWidget {
  const CustomerJobScreen({super.key, required this.state, required this.jobId});
  final AppState state;
  final String jobId;
  @override
  State<CustomerJobScreen> createState() => _CustomerJobScreenState();
}

class _CustomerJobScreenState extends State<CustomerJobScreen> {
  bool _byRating = false;
  Json? _job;
  Object? _error;
  Timer? _timer;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
    // Quiet refresh while the screen is open: new quotes, worker moving on the map, "finished".
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final j = await state.api.customerJob(widget.jobId);
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

  Future<void> _accept(Json job, Json bid) async {
    final l = L.of(context);
    final price = bid['price_inr'] as num;
    final fee = job['fee_inr'] as num? ?? 30;
    final w = bid['worker'] as Json;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.hireName(w['name'] as String)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line(l.workerPrice, inr(price)),
          _line(l.platformFee, inr(fee)),
          const Divider(height: 24),
          _line(l.youPay, inr(price + fee), bold: true),
          const SizedBox(height: 14),
          InfoBanner(icon: Icons.lock_rounded, color: BC.money, text: l.escrowExplain),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.continueToPay)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.api.acceptBid(job['id'] as String, bid['id'] as String);
      if (!mounted) return;
      await _openPayment(job, w['name'] as String, price, fee);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openPayment(Json job, String worker, num price, num fee) async {
    await Navigator.of(context).push(customerRoute<void>(
        builder: (_) => PaymentScreen(state: state, jobId: job['id'] as String, workerName: worker, price: price, fee: fee)));
    await _load();
  }

  Widget _line(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(a, style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
          const Spacer(),
          Text(b, style: TextStyle(fontSize: bold ? 20 : 16, fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontFeatures: BC.tabular)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final job = _job;
    return Scaffold(
      appBar: AppBar(title: Text(l.yourJob)),
      body: job == null
          ? (_error != null
              ? Center(child: OutlinedButton(onPressed: _load, child: Text(l.retry)))
              : const Center(child: CircularProgressIndicator(color: BC.brand)))
          : RefreshIndicator(color: BC.brand, onRefresh: _load, child: _body(l, job)),
    );
  }

  Widget _body(L l, Json job) {
    final status = job['status'] as String;
    final a = job['assignment'] as Json?;
    final bids = [...(job['bids'] as List).cast<Json>()];
    if (_byRating) bids.sort((x, y) => ((y['worker'] as Json)['rating'] as num).compareTo((x['worker'] as Json)['rating'] as num));
    final items = (job['work_items'] as List).cast<Json>();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)]),
      const SizedBox(height: 8),
      Text('📍 ${job['locality']} · ${scheduleText(l, job['scheduled_for'] as String?, job['time_slot'] as String?) ?? l.startsOn(job['start_date'] as String)}',
          style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
      const SizedBox(height: 14),
      if (a != null) ...[
        _Tracker(status: status, assignment: a),
        const SizedBox(height: 14),
        _NextStep(state: state, job: job, a: a, onPay: () => _openPayment(job, (a['worker'] as Json)['name'] as String, a['price_inr'] as num, job['fee_inr'] as num? ?? 30), reload: _load),
      ] else if (status == 'open' || status == 'bidding') ...[
        Row(children: [
          Expanded(child: Text(l.workersQuoted(bids.length), style: Theme.of(context).textTheme.titleLarge)),
          if (bids.length > 1)
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [ButtonSegment(value: false, label: BtnLabel(l.sortPrice)), ButtonSegment(value: true, label: BtnLabel(l.sortRating))],
              selected: {_byRating},
              onSelectionChanged: (s) => setState(() => _byRating = s.first),
            ),
        ]),
        const SizedBox(height: 10),
        if (bids.isEmpty) InfoBanner(icon: Icons.hourglass_top_rounded, color: const Color(0xFF92400E), text: l.waitingForQuotes),
        for (final (i, b) in bids.indexed) ...[
          _BidCard(
            bid: b,
            lowest: !_byRating && i == 0 && bids.length > 1,
            onAccept: () => _accept(job, b),
            onChat: () => openChat(context, state, jobId: job['id'] as String, withUser: (b['worker'] as Json)['id'] as String, title: (b['worker'] as Json)['name'] as String),
            onProfile: () => Navigator.of(context).push(customerRoute<void>(builder: (_) => WorkerProfileScreen(state: state, workerId: (b['worker'] as Json)['id'] as String))),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: () async {
            try {
              await state.api.cancelJob(job['id'] as String);
              if (mounted) Navigator.pop(context);
            } catch (e) {
              if (mounted) showError(context, e);
            }
          },
          icon: const Icon(Icons.cancel_outlined, color: BC.danger),
          label: Text(l.cancelJob, style: const TextStyle(color: BC.danger)),
        ),
      ] else
        StatusPill(label: l.statusCancelled, color: BC.closed, bg: BC.closedSoft),
      const SizedBox(height: 20),
      Text(l.workDetails, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      JobMap(lat: (job['lat'] as num).toDouble(), lng: (job['lng'] as num).toDouble(), exact: true, height: 130),
      const SizedBox(height: 12),
      for (final it in items) ...[WorkItemView(item: it, lang: state.language ?? 'hi'), const SizedBox(height: 12)],
    ]);
  }
}

/// Assigned → In progress → Completed → Rated → Paid
class _Tracker extends StatelessWidget {
  const _Tracker({required this.status, required this.assignment});
  final String status;
  final Json assignment;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final rated = (assignment['ratings'] as Map)['customer_to_worker'] != null;
    final paid = (assignment['payment'] as Map?)?['escrow_state'] == 'released';
    final reached = switch (status) {
      'assigned' => 0,
      'in_progress' => 1,
      'completed' => paid ? 4 : (rated ? 3 : 2),
      _ => 1,
    };
    final steps = [
      (l.stepAssigned, Icons.handshake_rounded),
      (l.stepInProgress, Icons.construction_rounded),
      (l.stepCompleted, Icons.task_alt_rounded),
      (l.stepRated, Icons.star_rounded),
      (l.stepPaid, Icons.payments_rounded),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Row(children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Column(children: [
                Row(children: [
                  Expanded(child: Container(height: 3, color: i == 0 ? Colors.transparent : (i <= reached ? BC.money : BC.line))),
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: i <= reached ? BC.money : BC.closedSoft,
                    child: Icon(steps[i].$2, size: 20, color: i <= reached ? Colors.white : BC.inkFaint),
                  ),
                  Expanded(child: Container(height: 3, color: i == steps.length - 1 ? Colors.transparent : (i < reached ? BC.money : BC.line))),
                ]),
                const SizedBox(height: 6),
                Text(steps[i].$1, textAlign: TextAlign.center, maxLines: 2,
                    style: TextStyle(fontSize: 12, fontWeight: i == reached ? FontWeight.w700 : FontWeight.w600, color: i <= reached ? BC.ink : BC.inkFaint)),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// ONE card that always says what happens next and offers the one action that matters.
class _NextStep extends StatelessWidget {
  const _NextStep({required this.state, required this.job, required this.a, required this.onPay, required this.reload});
  final AppState state;
  final Json job, a;
  final VoidCallback onPay;
  final Future<void> Function({bool silent}) reload;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = a['worker'] as Json;
    final name = w['name'] as String;
    final pay = a['payment'] as Json?;
    final escrow = pay?['escrow_state'] as String? ?? 'created';
    final status = job['status'] as String;
    final rated = (a['ratings'] as Map)['customer_to_worker'] != null;
    final tr = a['tracking'] as Json?;
    final att = (a['attendance'] as List).cast<Json>();

    Widget hero({required IconData icon, required Color color, required String title, String? sub, Widget? child, Widget? action}) => Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: color.withValues(alpha: 0.35))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              CircleAvatar(radius: 24, backgroundColor: color, child: Icon(icon, color: Colors.white)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                  if (sub != null) Text(sub, style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
                ]),
              ),
            ]),
            if (child != null) ...[const SizedBox(height: 14), child],
            if (action != null) ...[const SizedBox(height: 14), action],
          ]),
        );

    final workerRow = Row(children: [
      CircleAvatar(radius: 22, backgroundColor: BC.brand, child: Text(initials(name), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          StarBadge(w['rating'] as num, count: w['rating_count'] as int),
        ]),
      ),
      Text(inr(a['price_inr'] as num), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
    ]);

    late final Widget main;
    if (status == 'disputed') {
      main = hero(icon: Icons.gavel_rounded, color: BC.danger, title: l.statusDisputed, sub: l.disputeOpenCustomer);
    } else if (escrow == 'created') {
      main = hero(
        icon: Icons.account_balance_wallet_rounded,
        color: BC.brand,
        title: l.payToConfirm(name),
        sub: l.payToConfirmSub,
        child: workerRow,
        action: FilledButton.icon(onPressed: onPay, style: FilledButton.styleFrom(backgroundColor: BC.money), icon: const Icon(Icons.lock_rounded), label: BtnLabel(l.payNow)),
      );
    } else if (status == 'assigned' && tr == null) {
      main = hero(icon: Icons.schedule_rounded, color: BC.info, title: l.workerWillStart(name), sub: l.workerWillStartSub, child: workerRow);
    } else if (status == 'assigned' && tr != null && tr['arrived'] != true) {
      main = hero(
        icon: Icons.two_wheeler_rounded,
        color: BC.info,
        title: l.workerOnTheWay(name),
        sub: l.distanceEta((tr['distance_km'] as num).toStringAsFixed(1), (tr['eta_min'] as num).toInt()),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TrackingMap(
            houseLat: (job['lat'] as num).toDouble(),
            houseLng: (job['lng'] as num).toDouble(),
            workerLat: (tr['worker_lat'] as num?)?.toDouble(),
            workerLng: (tr['worker_lng'] as num?)?.toDouble(),
          ),
          const SizedBox(height: 10),
          workerRow,
        ]),
      );
    } else if (status == 'assigned' || status == 'in_progress') {
      final done = a['worker_done_at'] != null;
      main = hero(
        icon: done ? Icons.task_alt_rounded : Icons.construction_rounded,
        color: done ? BC.money : BC.info,
        title: done ? l.workerSaysDone(name) : l.workerAtSite(name),
        sub: done ? l.checkAndConfirm : (att.isNotEmpty ? l.attendanceDays(att.length) : null),
        child: workerRow,
        action: FilledButton.icon(
          onPressed: () => _confirmDone(context),
          style: FilledButton.styleFrom(backgroundColor: BC.money),
          icon: const Icon(Icons.task_alt_rounded),
          label: BtnLabel(l.workIsDone),
        ),
      );
    } else if (status == 'completed' && !rated && escrow == 'held') {
      main = hero(
        icon: Icons.star_rounded,
        color: BC.brand,
        title: l.rateToRelease,
        sub: l.ratingRequiredExplain(inr(pay?['worker_payout_inr'] as num?)),
        child: workerRow,
        action: FilledButton.icon(onPressed: () => _rate(context), icon: const Icon(Icons.star_rounded), label: BtnLabel(l.rateNow)),
      );
    } else {
      main = hero(
        icon: Icons.verified_rounded,
        color: BC.money,
        title: l.allDone,
        sub: pay == null ? null : l.escrowReleased(inr(pay['worker_payout_inr'] as num)),
        child: workerRow,
        action: pay == null
            ? null
            : OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(customerRoute<void>(
                    builder: (_) => ReceiptScreen(payment: pay, workerName: name, trades: (job['trades'] as List).cast<String>()))),
                icon: const Icon(Icons.receipt_long_rounded),
                label: BtnLabel(l.viewReceipt),
              ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      main,
      if (pay != null && escrow != 'created') ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
          child: Row(children: [
            Expanded(child: EscrowLine(state: escrow, amount: escrow == 'held' ? pay['amount_inr'] as num : pay['worker_payout_inr'] as num)),
            TextButton(
              onPressed: () => Navigator.of(context).push(customerRoute<void>(
                  builder: (_) => ReceiptScreen(payment: pay, workerName: name, trades: (job['trades'] as List).cast<String>()))),
              child: Text(l.receipt),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: () => openChat(context, state, jobId: job['id'] as String, withUser: w['id'] as String, title: name),
        icon: const Icon(Icons.chat_bubble_outline_rounded),
        label: BtnLabel(l.chatWithWorker),
      ),
      if (status != 'disputed' && escrow == 'held') ...[
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: () => _dispute(context),
          icon: const Icon(Icons.report_gmailerrorred_rounded, color: BC.danger),
          label: Text(l.reportProblem, style: const TextStyle(color: BC.danger)),
        ),
      ],
    ]);
  }

  Future<void> _confirmDone(BuildContext context) async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.workDoneQ),
        content: Text(l.workDoneSub),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.yesDone)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.api.completeJob(job['id'] as String);
      await reload();
      if (context.mounted) await _rate(context);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _rate(BuildContext context) async {
    final done = await Navigator.of(context).push<bool>(customerRoute(builder: (_) => RateWorkerScreen(state: state, job: job, a: a)));
    if (done == true) await reload();
  }

  Future<void> _dispute(BuildContext context) async {
    final l = L.of(context);
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.reportProblem),
        content: TextField(controller: c, maxLines: 4, decoration: InputDecoration(hintText: l.disputeHint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(l.submit)),
        ],
      ),
    );
    if (ok != true || c.text.trim().length < 5) return;
    try {
      await state.api.dispute(job['id'] as String, c.text.trim());
      await reload();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _BidCard extends StatelessWidget {
  const _BidCard({required this.bid, required this.lowest, required this.onAccept, required this.onChat, required this.onProfile});
  final Json bid;
  final bool lowest;
  final VoidCallback onAccept, onChat, onProfile;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = bid['worker'] as Json;
    final badges = (w['badges'] as List).cast<String>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: onProfile,
            child: Row(children: [
              CircleAvatar(radius: 26, backgroundColor: BC.brand, child: Text(initials(w['name'] as String), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(w['name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                    if (w['verified'] == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, color: BC.info, size: 18)),
                  ]),
                  Row(children: [
                    StarBadge(w['rating'] as num),
                    Flexible(child: Text('  ·  ${l.jobsDone((w['completed_jobs'] as num).toInt())}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600))),
                  ]),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(inr(bid['price_inr'] as num), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
                if (lowest) StatusPill(label: l.lowest, color: BC.money, bg: BC.moneySoft),
              ]),
            ]),
          ),
          if (bid['fair'] is Map) ...[
            const SizedBox(height: 10),
            FairBidBadge(fair: (bid['fair'] as Map).cast<String, dynamic>()),
          ],
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final b in badges)
                StatusPill(label: '🏅 ${badgeLabel(l, b, w['rating'] as num, w['rating_count'] as int)}', color: const Color(0xFFB45309), bg: BC.pendingSoft),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 52,
              height: 52,
              child: IconButton.outlined(
                onPressed: onChat,
                tooltip: l.chat,
                style: IconButton.styleFrom(side: const BorderSide(color: BC.line), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r))),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: bid['status'] == 'pending' ? onAccept : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.handshake_rounded),
                label: Text(l.accept, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// C5 — five parameters; Overall = average of the four operational ones (computed, not asked).
class RateWorkerScreen extends StatefulWidget {
  const RateWorkerScreen({super.key, required this.state, required this.job, required this.a});
  final AppState state;
  final Json job, a;
  @override
  State<RateWorkerScreen> createState() => _RateWorkerScreenState();
}

class _RateWorkerScreenState extends State<RateWorkerScreen> {
  final _v = {'quality': 0, 'timeliness': 0, 'behaviour': 0, 'value_for_money': 0};
  final _comment = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  double get _overall => _v.values.every((x) => x > 0) ? _v.values.reduce((a, b) => a + b) / 4 : 0;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = widget.a['worker'] as Json;
    final pay = widget.a['payment'] as Json?;
    final labels = {
      'quality': (l.rateQuality, Icons.construction_rounded),
      'timeliness': (l.rateTimeliness, Icons.schedule_rounded),
      'behaviour': (l.rateBehaviour, Icons.sentiment_satisfied_rounded),
      'value_for_money': (l.rateValue, Icons.currency_rupee_rounded),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l.rateName(w['name'] as String))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        InfoBanner(icon: Icons.lock_clock_rounded, color: const Color(0xFF92400E), text: l.ratingRequiredExplain(inr(pay?['worker_payout_inr'] as num?))),
        const SizedBox(height: 16),
        for (final e in labels.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(e.value.$2, color: BC.inkSoft),
                    const SizedBox(width: 8),
                    Text(e.value.$1, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 6),
                  StarInput(value: _v[e.key]!, onChanged: (x) => setState(() => _v[e.key] = x), size: 44),
                ]),
              ),
            ),
          ),
        Card(
          color: BC.ink,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Text(l.overallExperience, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
              const Spacer(),
              const Icon(Icons.star_rounded, color: BC.pending, size: 30),
              Text(_overall == 0 ? '—' : _overall.toStringAsFixed(2),
                  style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        TextField(controller: _comment, maxLines: 3, maxLength: 500, decoration: InputDecoration(hintText: l.commentOptional)),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _overall == 0 || _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final r = await widget.state.api.rateWorker(widget.job['id'] as String, {..._v, 'comment': _comment.text.trim().isEmpty ? null : _comment.text.trim()});
                    if (!context.mounted) return;
                    HapticFeedback.heavyImpact();
                    await showDialog<void>(
                      context: context,
                      builder: (c) => AlertDialog(
                        icon: const Icon(Icons.payments_rounded, color: BC.money, size: 64),
                        title: Text(l.paymentReleased, textAlign: TextAlign.center),
                        content: Text(l.paymentReleasedSub(inr(((r['payment'] as Map?)?['worker_payout_inr'] as num?) ?? 0), w['name'] as String),
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
                      ),
                    );
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          icon: const Icon(Icons.lock_open_rounded),
          label: BtnLabel(l.submitAndRelease),
        ),
      ]),
    );
  }
}
