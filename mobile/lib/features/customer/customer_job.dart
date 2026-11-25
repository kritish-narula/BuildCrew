import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/poller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/fair_price.dart';
import 'customer_home.dart' show customerRoute;
import '../../widgets/maps.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';
import '../../widgets/trust_widgets.dart';
import '../common/chat.dart';
import '../common/completion_ui.dart';
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
  String _sort = 'price'; // price | rating | verified (police-verified workers first)
  Json? _job;
  Object? _error;
  late final Poller _poller;
  final _acting = ValueNotifier<bool>(false); // a button's request is in flight: no polling, no double taps
  String? _uid;
  int _seq = 0, _applied = 0; // an older response arriving late must never overwrite a newer one

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _uid = state.user?.id;
    state.addListener(_onState);
    _load();
    // Quiet refresh while the screen is open and the app is in the foreground: new quotes, worker moving on the
    // map, "finished". Pull-to-refresh and every action refresh immediately.
    _poller = Poller(const Duration(seconds: 3), () => _load(silent: true), enabled: () => !_acting.value)..start();
  }

  @override
  void dispose() {
    _poller.dispose();
    state.removeListener(_onState);
    _acting.dispose();
    super.dispose();
  }

  /// Another account signed in on this phone: this job belongs to the old one.
  void _onState() {
    if (mounted && state.user?.id != _uid) Navigator.of(context).maybePop();
  }

  Future<void> _load({bool silent = false}) async {
    final seq = ++_seq;
    try {
      final j = await state.api.customerJob(widget.jobId);
      if (!mounted || seq < _applied) return;
      _applied = seq;
      setState(() {
        _job = j;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && (e.code == 'err.not_found' || e.code == 'err.not_your_job')) {
        Navigator.of(context).maybePop(); // not this account's job (account switched mid-flow)
        return;
      }
      if (!silent && _job == null) setState(() => _error = e);
    }
  }

  Future<void> _nudge(Json job) async {
    final l = L.of(context);
    try {
      await state.api.nudgeJob(job['id'] as String);
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: BC.money, content: Text(l.nudgeSent, style: const TextStyle(fontSize: 15, color: Colors.white))));
    } catch (e) {
      if (mounted) showError(context, e);
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
    bool police(Json b) => (b['worker'] as Json)['police_verified'] == true;
    if (_sort == 'rating') {
      // best rated first; at equal rating the police-verified worker ranks higher
      bids.sort((x, y) {
        final c = ((y['worker'] as Json)['rating'] as num).compareTo((x['worker'] as Json)['rating'] as num);
        return c != 0 ? c : (police(y) ? 1 : 0).compareTo(police(x) ? 1 : 0);
      });
    } else if (_sort == 'verified') {
      bids.sort((x, y) {
        final c = (police(y) ? 1 : 0).compareTo(police(x) ? 1 : 0);
        return c != 0 ? c : (x['price_inr'] as num).compareTo(y['price_inr'] as num);
      });
    }
    final refix = a != null && a['kind'] == 'refix';
    final direct = (job['direct'] as Map?)?.cast<String, dynamic>();
    final items = (job['work_items'] as List).cast<Json>();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)]),
      const SizedBox(height: 8),
      Text('📍 ${job['locality']} · ${scheduleText(l, job['scheduled_for'] as String?, job['time_slot'] as String?) ?? l.startsOn(job['start_date'] as String)}',
          style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
      const SizedBox(height: 14),
      if (refix) ...[
        InfoBanner(icon: Icons.build_circle_rounded, color: BC.info, text: l.refixCustomerSub((a!['worker'] as Json)['name'] as String)),
        const SizedBox(height: 14),
      ],
      if (a != null) ...[
        if (!refix) _Tracker(status: status, assignment: a),
        if (!refix) const SizedBox(height: 14),
        ValueListenableBuilder<bool>(
          valueListenable: _acting,
          builder: (_, acting, __) => _NextStep(
              state: state, job: job, a: a, busy: _acting, acting: acting,
              onPay: () => _openPayment(job, (a['worker'] as Json)['name'] as String, a['price_inr'] as num, job['fee_inr'] as num? ?? 30),
              reload: _load),
        ),
      ] else if (status == 'open' || status == 'bidding') ...[
        Text(l.workersQuoted(bids.length), style: Theme.of(context).textTheme.titleLarge),
        if (direct != null) ...[
          const SizedBox(height: 10),
          InfoBanner(
            icon: direct['state'] == 'pending' ? Icons.hourglass_top_rounded : Icons.groups_rounded,
            color: direct['state'] == 'pending' ? BC.info : BC.inkSoft,
            text: switch (direct['state']) {
              'pending' => l.directWaiting(((direct['worker'] as Map)['name'] as String).split(' ').first),
              'declined' => l.directDeclined(((direct['worker'] as Map)['name'] as String).split(' ').first),
              _ => l.directExpired(((direct['worker'] as Map)['name'] as String).split(' ').first),
            },
          ),
        ],
        if (bids.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final (code, label) in [('price', l.sortPrice), ('rating', l.sortRating), ('verified', l.sortVerified)])
              ChoiceChip(label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis), selected: _sort == code, onSelected: (_) => setState(() => _sort = code)),
          ]),
        ],
        const SizedBox(height: 10),
        if (bids.isEmpty) InfoBanner(icon: Icons.hourglass_top_rounded, color: const Color(0xFF92400E), text: l.waitingForQuotes),
        if (job['no_quotes_24h'] == true) ...[
          const SizedBox(height: 10),
          AppCard(
            color: BC.pendingSoft,
            borderColor: BC.pending.withValues(alpha: 0.5),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.lightbulb_rounded, color: BC.pendingInk),
                const SizedBox(width: 8),
                Expanded(child: Text(l.noQuotesTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: BC.pendingInk))),
              ]),
              const SizedBox(height: 6),
              Text(l.noQuotesBody, style: BC.subtle),
              const SizedBox(height: 10),
              SecondaryButton(icon: Icons.notifications_active_rounded, label: l.remindWorkers, onPressed: () => _nudge(job)),
            ]),
          ),
        ],
        for (final (i, b) in bids.indexed) ...[
          _BidCard(
            bid: b,
            lowest: _sort == 'price' && i == 0 && bids.length > 1,
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
  const _NextStep({required this.state, required this.job, required this.a, required this.onPay, required this.reload, required this.busy, required this.acting});
  final AppState state;
  final Json job, a;
  final VoidCallback onPay;
  final Future<void> Function({bool silent}) reload;
  final ValueNotifier<bool> busy; // shared "an action is running" flag (also pauses polling)
  final bool acting;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = a['worker'] as Json;
    final name = w['name'] as String;
    final pay = a['payment'] as Json?;
    final refix = a['kind'] == 'refix'; // free warranty visit: nothing to pay, nothing to rate
    final escrow = pay?['escrow_state'] as String? ?? (refix ? 'free' : 'created');
    final status = job['status'] as String;
    final rated = (a['ratings'] as Map)['customer_to_worker'] != null;
    final tr = a['tracking'] as Json?;
    final warranty = (a['warranty'] as Map?)?.cast<String, dynamic>();
    final codeView = (a['start_code'] as Map?)?.cast<String, dynamic>();
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
        action: SecondaryButton(icon: Icons.share_rounded, label: l.shareTrip, onPressed: () => showShareTripSheet(context, state.api, job['id'] as String)),
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
      if (a['rework_open'] == true) {
        final round = (a['rework_count'] as num?)?.toInt() ?? 1;
        main = hero(
          icon: Icons.replay_rounded,
          color: BC.pendingInk,
          title: l.reworkWaiting(name),
          sub: l.reworkWaitingSub(round, round + ((a['rework_left'] as num?)?.toInt() ?? 0)),
          child: workerRow,
        );
      } else if (done) {
        final hours = hoursUntil(a['auto_confirm_at'] as String?);
        final note = (a['worker_done_note'] as String?) ?? '';
        main = hero(
          icon: Icons.task_alt_rounded,
          color: BC.money,
          title: l.workerSaysDone(name),
          sub: l.checkAndConfirm,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            workerRow,
            const SizedBox(height: 12),
            Text(l.compareTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            BeforeAfter(
              before: ((a['before_photos'] as List?) ?? const []).cast<String>(),
              after: ((a['proof_photos'] as List?) ?? const []).cast<String>(),
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('${l.workerNoteLabel}: $note', maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, height: 1.4)),
            ],
            if (hours != null) ...[
              const SizedBox(height: 12),
              InfoBanner(icon: Icons.timer_rounded, color: BC.pendingInk, text: l.doneBannerCountdown(hours)),
            ],
          ]),
          action: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PrimaryButton(color: BC.money, icon: Icons.task_alt_rounded, label: l.yesWorkDone, busy: acting, onPressed: () => _confirmDone(context)),
            const SizedBox(height: 10),
            SecondaryButton(icon: Icons.replay_rounded, label: l.notDoneSendBack, onPressed: acting ? null : () => _sendBack(context, name)),
          ]),
        );
      } else {
        main = hero(
          icon: Icons.construction_rounded,
          color: BC.info,
          title: l.workerAtSite(name),
          sub: att.isNotEmpty ? l.attendanceDays(att.length) : null,
          child: workerRow,
          action: FilledButton.icon(
            onPressed: acting ? null : () => _confirmDone(context),
            style: FilledButton.styleFrom(backgroundColor: BC.money),
            icon: const Icon(Icons.task_alt_rounded),
            label: BtnLabel(l.workIsDone),
          ),
        );
      }
    } else if (status == 'completed' && !rated && escrow == 'held') {
      main = hero(
        icon: Icons.star_rounded,
        color: BC.brand,
        title: l.rateToRelease,
        sub: l.ratingRequiredExplain(inr(pay?['worker_payout_inr'] as num?)),
        child: workerRow,
        action: FilledButton.icon(onPressed: () => _rate(context), icon: const Icon(Icons.star_rounded), label: BtnLabel(l.rateNow)),
      );
    } else if (refix) {
      main = hero(icon: Icons.verified_rounded, color: BC.money, title: l.refixDoneTitle, sub: l.refixDoneSub, child: workerRow);
    } else {
      main = hero(
        icon: Icons.verified_rounded,
        color: BC.money,
        title: l.allDone,
        sub: pay == null ? null : l.escrowReleased(inr(pay['worker_payout_inr'] as num)),
        child: a['auto_confirmed'] == true && escrow == 'released'
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [workerRow, const SizedBox(height: 10), InfoBanner(icon: Icons.timer_rounded, color: BC.money, text: l.autoReleasedCustomer)])
            : workerRow,
        action: pay == null
            ? null
            : OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(customerRoute<void>(
                    builder: (_) => ReceiptScreen(
                        payment: pay, workerName: name, trades: (job['trades'] as List).cast<String>(), warrantyDays: (warranty?['days'] as num?)?.toInt() ?? 0))),
                icon: const Icon(Icons.receipt_long_rounded),
                label: BtnLabel(l.viewReceipt),
              ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      main,
      // The 4-digit start code: shown big after paying, until the worker has typed it.
      if (codeView != null && codeView['needed'] == true && status != 'disputed') ...[
        const SizedBox(height: 12),
        StartCodeCard(view: codeView, workerName: name),
      ],
      if (warranty != null && ((warranty['days'] as num?) ?? 0) > 0 && (escrow == 'released' || escrow == 'split')) ...[
        const SizedBox(height: 12),
        _WarrantyCard(state: state, job: job, a: a, warranty: warranty, workerName: name, reload: reload),
      ],
      if (pay != null && escrow != 'created') ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
          child: Row(children: [
            Expanded(child: EscrowLine(state: escrow, amount: escrow == 'held' ? pay['amount_inr'] as num : pay['worker_payout_inr'] as num)),
            TextButton(
              onPressed: () => Navigator.of(context).push(customerRoute<void>(
                  builder: (_) => ReceiptScreen(
                      payment: pay, workerName: name, trades: (job['trades'] as List).cast<String>(), warrantyDays: (warranty?['days'] as num?)?.toInt() ?? 0))),
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
          onPressed: acting ? null : () => _dispute(context),
          icon: const Icon(Icons.report_gmailerrorred_rounded, color: BC.danger),
          label: Text(l.reportProblem, style: const TextStyle(color: BC.danger)),
        ),
      ],
      // ---- before work starts: the customer can always walk away (money back in full) or pick someone else
      if (status == 'assigned' && a['started_at'] == null) ...[
        if (a['can_report_no_show'] == true) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: BC.danger.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.danger.withValues(alpha: 0.4))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(l.noShowTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: BC.danger)),
              Text(l.noShowSub, style: BC.subtle),
              const SizedBox(height: 10),
              PrimaryButton(color: BC.danger, icon: Icons.person_off_rounded, label: l.noShowBtn, busy: acting, onPressed: () => _noShow(context)),
            ]),
          ),
        ],
        if (a['worker_suspended'] == true) ...[
          const SizedBox(height: 10),
          InfoBanner(icon: Icons.block_rounded, color: BC.danger, text: l.workerSuspendedBanner),
        ],
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: TextButton.icon(
              onPressed: acting ? null : () => _changeWorker(context),
              icon: const Icon(Icons.swap_horiz_rounded),
              label: Text(l.changeWorker, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: acting ? null : () => _cancelHire(context),
              icon: const Icon(Icons.cancel_outlined, color: BC.danger),
              label: Text(l.cancelJob, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.danger)),
            ),
          ),
        ]),
      ],
      if (((a['timeline'] as List?) ?? const []).isNotEmpty) ...[
        const SizedBox(height: 10),
        CompletionTimeline(events: (a['timeline'] as List).cast<Json>()),
      ],
      // ---- demo only: pretend time passes (48 h auto-confirm, arrival time, support's decision)
      if (status == 'disputed') DemoTimeSkip(state: state, jobId: job['id'] as String, label: l.demoSkipSupport, by: const Duration(hours: 24), onDone: () => reload()),
      if (status == 'in_progress' && a['auto_confirm_at'] != null)
        DemoTimeSkip(state: state, jobId: job['id'] as String, label: l.demoSkip48, by: const Duration(hours: 48), onDone: () => reload()),
      if (status == 'assigned' && a['started_at'] == null && a['can_report_no_show'] != true && a['no_show_after'] != null)
        DemoTimeSkip(state: state, jobId: job['id'] as String, label: l.demoSkipEta, by: const Duration(hours: 2), onDone: () => reload()),
    ]);
  }

  /// One action at a time; polling pauses meanwhile; errors become friendly snackbars.
  Future<void> _guard(BuildContext context, Future<void> Function() fn) async {
    if (busy.value) return;
    busy.value = true;
    try {
      await fn();
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      busy.value = false;
    }
  }

  void _snack(BuildContext context, String text, {Color color = BC.ink}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(backgroundColor: color, content: Text(text, style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white))));
  }

  Future<bool> _ask(BuildContext context, String title, String body, String yes, {bool danger = false}) async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), style: danger ? FilledButton.styleFrom(backgroundColor: BC.danger) : null, child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _sendBack(BuildContext context, String name) async {
    final l = L.of(context);
    final r = await showSendBackSheet(context, left: (a['rework_left'] as num?)?.toInt() ?? 0);
    if (r == null || !context.mounted) return;
    await _guard(context, () async {
      final keys = await uploadPhotos(state.api, r.photos);
      final out = await state.api.sendBack(job['id'] as String, reasons: r.reasons, note: r.note, photos: keys);
      await reload();
      _snack(context, out['outcome'] == 'disputed' ? l.sentBackDisputed : l.sentBackDone(name), color: out['outcome'] == 'disputed' ? BC.danger : BC.money);
    });
  }

  Future<void> _noShow(BuildContext context) async {
    final l = L.of(context);
    if (!await _ask(context, l.noShowBtn, l.noShowConfirmBody, l.noShowBtn, danger: true) || !context.mounted) return;
    await _guard(context, () async {
      final out = await state.api.reportNoShow(job['id'] as String);
      await reload();
      final refunded = (out['refunded_inr'] as num?) ?? 0;
      _snack(context, refunded > 0 ? l.noShowDone(inr(refunded)) : l.noShowDoneFree, color: BC.money);
    });
  }

  Future<void> _changeWorker(BuildContext context) async {
    final l = L.of(context);
    if (!await _ask(context, l.changeWorker, l.changeWorkerBody, l.changeWorker) || !context.mounted) return;
    await _guard(context, () async {
      await state.api.reopenJob(job['id'] as String);
      await reload();
      _snack(context, l.changeWorkerDone, color: BC.money);
    });
  }

  Future<void> _cancelHire(BuildContext context) async {
    final l = L.of(context);
    if (!await _ask(context, l.cancelJob, l.cancelHireBody, l.cancelJob, danger: true) || !context.mounted) return;
    await _guard(context, () async {
      final out = await state.api.cancelJob(job['id'] as String);
      await reload();
      final refunded = (out['refunded_inr'] as num?) ?? 0;
      _snack(context, refunded > 0 ? l.cancelledRefund(inr(refunded)) : l.cancelledFree);
    });
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
    if (ok != true || !context.mounted) return;
    await _guard(context, () async {
      await state.api.completeJob(job['id'] as String);
      await reload();
      if (context.mounted && a['kind'] != 'refix') await _rate(context); // a free re-fix has nothing to rate
    });
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
        content: TextField(controller: c, maxLines: 4, maxLength: 1000, decoration: InputDecoration(hintText: l.disputeHint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(l.submit)),
        ],
      ),
    );
    final text = c.text.trim();
    if (ok != true || text.length < 5 || !context.mounted) return;
    await _guard(context, () async {
      await state.api.dispute(job['id'] as String, text);
      await reload();
      _snack(context, l.reportedSnack);
    });
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
                    WorkerMarks(w),
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
          if ((w['level'] != null && w['level'] != 'helper') || ((bid['warranty_days'] as num?) ?? 0) > 0) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              LevelChip(w['level'] as String?),
              WarrantyChip(((bid['warranty_days'] as num?) ?? 0).toInt()),
            ]),
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
                    if (context.mounted) {
                      showError(context, e);
                      // rated twice / released automatically while this screen was open: nothing left to do here
                      if (e is ApiException && e.code == 'err.already_rated') Navigator.pop(context, true);
                    }
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


/// After release: "Guaranteed until ..." with "Problem came back" (free re-fix by the same worker), or why it is not possible.
class _WarrantyCard extends StatefulWidget {
  const _WarrantyCard({required this.state, required this.job, required this.a, required this.warranty, required this.workerName, required this.reload});
  final AppState state;
  final Json job, a, warranty;
  final String workerName;
  final Future<void> Function({bool silent}) reload;
  @override
  State<_WarrantyCard> createState() => _WarrantyCardState();
}

class _WarrantyCardState extends State<_WarrantyCard> {
  bool _busy = false;

  String _date(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.day}/${d.month}/${d.year}';
  }

  Future<void> _report() async {
    final l = L.of(context);
    final r = await showModalBottomSheet<(String, List<String>)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _WarrantySheet(workerName: widget.workerName),
    );
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final keys = await uploadPhotos(widget.state.api, r.$2);
      final out = await widget.state.api.requestRefix(widget.job['id'] as String, reason: r.$1, photos: keys);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: BC.money, content: Text(l.warrantyRequested(widget.workerName), style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white))));
      await widget.reload();
      if (mounted) {
        await Navigator.of(context).push(customerRoute<void>(builder: (_) => CustomerJobScreen(state: widget.state, jobId: out['job_id'] as String)));
        await widget.reload();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = widget.warranty;
    final until = w['until'] as String?;
    final reason = w['reason'] as String?;
    final Widget body;
    if (w['can_request'] == true && until != null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.warrantyUntil(_date(until)), style: BC.subtle),
        const SizedBox(height: 12),
        PrimaryButton(icon: Icons.build_circle_rounded, label: l.warrantyProblem, busy: _busy, color: BC.info, onPressed: _report),
      ]);
    } else if (reason == 'open') {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.warrantyOpen, style: BC.subtle),
        if (w['open_job_id'] != null) ...[
          const SizedBox(height: 10),
          SecondaryButton(
            icon: Icons.visibility_rounded,
            label: l.warrantyOpenView,
            onPressed: () => Navigator.of(context).push(customerRoute<void>(builder: (_) => CustomerJobScreen(state: widget.state, jobId: w['open_job_id'] as String))),
          ),
        ],
      ]);
    } else if (reason == 'limit') {
      body = Text(l.warrantyLimit((w['refixes_used'] as num).toInt(), (w['refixes_max'] as num).toInt()), style: BC.subtle);
    } else {
      body = Text(until == null ? l.warrantyChip((w['days'] as num).toInt()) : l.warrantyExpired(_date(until)), style: BC.subtle);
    }
    return AppCard(
      color: BC.infoSoft,
      borderColor: BC.info.withValues(alpha: 0.35),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconBadge(Icons.build_circle_rounded, color: BC.info, size: 40, solid: true),
          const SizedBox(width: 12),
          Expanded(child: Text(l.warrantyTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge)),
          WarrantyChip((w['days'] as num).toInt()),
        ]),
        const SizedBox(height: 10),
        body,
      ]),
    );
  }
}

/// "Problem came back": what happened + at least one photo.
class _WarrantySheet extends StatefulWidget {
  const _WarrantySheet({required this.workerName});
  final String workerName;
  @override
  State<_WarrantySheet> createState() => _WarrantySheetState();
}

class _WarrantySheetState extends State<_WarrantySheet> {
  final _reason = TextEditingController();
  List<String> _photos = [];

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final ok = _reason.text.trim().length >= 5 && _photos.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.warrantySheetTitle, style: context.tt.titleLarge),
            const SizedBox(height: 6),
            Text(l.warrantySheetSub(widget.workerName), style: BC.subtle),
            const SizedBox(height: 14),
            TextField(controller: _reason, maxLines: 3, maxLength: 500, decoration: InputDecoration(hintText: l.warrantyReasonHint), onChanged: (_) => setState(() {})),
            const SizedBox(height: 4),
            Text(l.warrantyPhotosHint, style: BC.caption),
            const SizedBox(height: 8),
            PhotoPickerRow(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
            const SizedBox(height: 16),
            PrimaryButton(
              icon: Icons.build_circle_rounded,
              color: BC.info,
              label: l.warrantySend,
              onPressed: ok ? () => Navigator.pop(context, (_reason.text.trim(), _photos)) : null,
            ),
          ]),
        ),
      ),
    );
  }
}
