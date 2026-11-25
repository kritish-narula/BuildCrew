import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../common/chat.dart';
import '../worker/assignment_screen.dart' show EscrowLine;
import '../worker/job_detail.dart' show WorkItemView;
import '../worker/worker_shell.dart' show badgeLabel, initials;
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
  final _key = GlobalKey();

  Future<void> _accept(Json job, Json bid, Future<void> Function() reload) async {
    final l = L.of(context);
    final price = bid['price_inr'] as num;
    final fee = job['fee_inr'] as num? ?? 30;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.hireName((bid['worker'] as Json)['name'] as String)),
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
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.payAndHire)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // With live Razorpay keys, Checkout opens here; escrow becomes HELD on the verified webhook.
      await widget.state.api.acceptBid(job['id'] as String, bid['id'] as String);
      HapticFeedback.mediumImpact();
      await reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _line(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(a, style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
          const Spacer(),
          Text(b, style: TextStyle(fontSize: bold ? 20 : 16, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontFeatures: BC.tabular)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.yourJob)),
      body: AsyncList<Json>(
        key: _key,
        load: () => widget.state.api.customerJob(widget.jobId),
        builder: (ctx, job, reload) {
          final status = job['status'] as String;
          final a = job['assignment'] as Json?;
          final bids = [...(job['bids'] as List).cast<Json>()];
          if (_byRating) bids.sort((x, y) => ((y['worker'] as Json)['rating'] as num).compareTo((x['worker'] as Json)['rating'] as num));
          final items = (job['work_items'] as List).cast<Json>();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)]),
            const SizedBox(height: 8),
            Text('📍 ${job['locality']} · ${l.startsOn(job['start_date'] as String)}', style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (a != null) ...[
              _Tracker(status: status, assignment: a),
              const SizedBox(height: 16),
              _AssignedCard(state: widget.state, job: job, a: a, reload: reload),
            ] else if (status == 'open' || status == 'bidding') ...[
              Row(children: [
                Expanded(child: Text(l.workersQuoted(bids.length), style: Theme.of(context).textTheme.titleLarge)),
                if (bids.length > 1)
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: [ButtonSegment(value: false, label: Text(l.sortPrice)), ButtonSegment(value: true, label: Text(l.sortRating))],
                    selected: {_byRating},
                    onSelectionChanged: (s) => setState(() => _byRating = s.first),
                  ),
              ]),
              const SizedBox(height: 10),
              if (bids.isEmpty)
                InfoBanner(icon: Icons.hourglass_top_rounded, color: const Color(0xFF92400E), text: l.waitingForQuotes),
              for (final (i, b) in bids.indexed) ...[
                _BidCard(
                  bid: b,
                  lowest: !_byRating && i == 0 && bids.length > 1,
                  onAccept: () => _accept(job, b, reload),
                  onChat: () => openChat(context, widget.state, jobId: job['id'] as String, withUser: (b['worker'] as Json)['id'] as String,
                      title: (b['worker'] as Json)['name'] as String),
                  onProfile: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => WorkerProfileScreen(state: widget.state, workerId: (b['worker'] as Json)['id'] as String))),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () async {
                  try {
                    await widget.state.api.cancelJob(job['id'] as String);
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
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
            for (final it in items) ...[WorkItemView(item: it, lang: widget.state.language ?? 'hi'), const SizedBox(height: 12)],
          ]);
        },
      ),
    );
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
                    style: TextStyle(fontSize: 12, fontWeight: i == reached ? FontWeight.w800 : FontWeight.w600, color: i <= reached ? BC.ink : BC.inkFaint)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _AssignedCard extends StatelessWidget {
  const _AssignedCard({required this.state, required this.job, required this.a, required this.reload});
  final AppState state;
  final Json job, a;
  final Future<void> Function() reload;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = a['worker'] as Json;
    final pay = a['payment'] as Json?;
    final status = job['status'] as String;
    final rated = (a['ratings'] as Map)['customer_to_worker'] != null;
    final att = (a['attendance'] as List).cast<Json>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 26, backgroundColor: BC.brand, child: Text(initials(w['name'] as String), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(w['name'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  StarBadge(w['rating'] as num, count: w['rating_count'] as int),
                ]),
              ),
              Text(inr(a['price_inr'] as num), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
            ]),
            if (pay != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: BC.bg, borderRadius: BorderRadius.circular(12)),
                child: EscrowLine(state: pay['escrow_state'] as String, amount: pay['escrow_state'] == 'held' ? pay['amount_inr'] as num : pay['worker_payout_inr'] as num),
              ),
            ],
            if (att.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l.attendanceDays(att.length), style: const TextStyle(fontWeight: FontWeight.w700)),
              for (final x in att)
                Text('• ${(x['in'] as String).substring(0, 10)}  ${(x['in'] as String).substring(11, 16)}–${x['out'] == null ? '…' : (x['out'] as String).substring(11, 16)}'
                    '${x['geofence_ok'] == true ? '' : '  ⚠️'}${x['offline'] == true ? '  ☁︎' : ''}',
                    style: const TextStyle(color: BC.inkSoft, fontFeatures: BC.tabular)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (status == 'assigned' || status == 'in_progress') ...[
        FilledButton.icon(
          onPressed: () async {
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
          },
          style: FilledButton.styleFrom(backgroundColor: BC.money),
          icon: const Icon(Icons.task_alt_rounded),
          label: Text(l.workIsDone),
        ),
        const SizedBox(height: 10),
      ],
      // C5: payment is released ONLY through this rating.
      if (status == 'completed' && !rated) ...[
        FilledButton.icon(
          onPressed: () => _rate(context),
          icon: const Icon(Icons.star_rounded),
          label: Text(l.rateToRelease),
        ),
        const SizedBox(height: 10),
      ],
      OutlinedButton.icon(
        onPressed: () => openChat(context, state, jobId: job['id'] as String, withUser: w['id'] as String, title: w['name'] as String),
        icon: const Icon(Icons.chat_bubble_outline_rounded),
        label: Text(l.chatWithWorker),
      ),
      if (status != 'disputed' && !(pay?['escrow_state'] == 'released')) ...[
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: () => _dispute(context),
          icon: const Icon(Icons.report_gmailerrorred_rounded, color: BC.danger),
          label: Text(l.reportProblem, style: const TextStyle(color: BC.danger)),
        ),
      ],
      if (status == 'disputed') InfoBanner(icon: Icons.gavel_rounded, color: BC.danger, text: l.disputeOpenCustomer),
    ]);
  }

  Future<void> _rate(BuildContext context) async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => RateWorkerScreen(state: state, job: job, a: a)));
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
              CircleAvatar(radius: 26, backgroundColor: BC.brand, child: Text(initials(w['name'] as String), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(w['name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                    if (w['verified'] == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, color: BC.info, size: 18)),
                  ]),
                  Row(children: [
                    StarBadge(w['rating'] as num),
                    Text('  ·  ${l.jobsDone(w['completed_jobs'] as int)}', style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(inr(bid['price_inr'] as num), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
                if (lowest) StatusPill(label: l.lowest, color: BC.money, bg: BC.moneySoft),
              ]),
            ]),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final b in badges)
                StatusPill(label: '🏅 ${badgeLabel(l, b, w['rating'] as num, w['rating_count'] as int)}', color: const Color(0xFFB45309), bg: BC.pendingSoft),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(onPressed: onChat, icon: const Icon(Icons.chat_bubble_outline_rounded), label: Text(l.chat)),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: bid['status'] == 'pending' ? onAccept : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(BC.tap)),
                icon: const Icon(Icons.handshake_rounded),
                label: Text(l.accept),
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
                  style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
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
          label: Text(l.submitAndRelease),
        ),
      ]),
    );
  }
}
