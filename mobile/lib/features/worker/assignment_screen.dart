import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/app_state.dart';
import '../../core/outbox.dart';
import '../../core/poller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/maps.dart';
import '../../widgets/media.dart';
import '../../widgets/trust_widgets.dart';
import '../common/chat.dart';
import '../common/completion_ui.dart';
import '../common/help.dart';
import 'worker_shell.dart' show PendingChip;

/// The job the worker has WON: address, attendance (S9), escrow status, rate the customer.
/// Check-in/out capture selfie + GPS and go through the offline Outbox — they work with no
/// signal and sync later with their original timestamps.
class AssignmentScreen extends StatefulWidget {
  const AssignmentScreen({super.key, required this.state, required this.assignmentId});
  final AppState state;
  final String assignmentId;
  @override
  State<AssignmentScreen> createState() => _AssignmentScreenState();
}

class _AssignmentScreenState extends State<AssignmentScreen> {
  bool _busy = false;
  Json? _a;
  bool _loadFailed = false;
  bool _gone = false; // the hire ended (customer cancelled / chose someone else / reported no-show)
  Timer? _share;
  late final Poller _poller;
  String? _uid;
  int _seq = 0, _applied = 0; // an older response arriving late must never overwrite a newer one

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _uid = state.user?.id;
    state.addListener(_onState);
    _load();
    _poller = Poller(const Duration(seconds: 3), _load, enabled: () => !_busy)..start();
  }

  @override
  void dispose() {
    _poller.dispose();
    _share?.cancel();
    state.removeListener(_onState);
    super.dispose();
  }

  bool _spoken = false;
  String _headline = '';

  /// Reads the current next step once when the screen opens (unless auto-read is switched off in Profile).
  void _autoRead(Json a) {
    if (_spoken || _headline.isEmpty) return;
    _spoken = true;
    ReadAloud.auto(_headline, state.language ?? 'hi');
  }

  /// Another account signed in on this phone: this screen belongs to the old one.
  void _onState() {
    if (mounted && state.user?.id != _uid) Navigator.of(context).maybePop();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    try {
      final all = await state.api.assignments();
      final a = all.where((x) => x['id'] == widget.assignmentId).firstOrNull;
      if (!mounted || seq < _applied) return;
      _applied = seq;
      if (a == null) {
        setState(() => _gone = true);
        _share?.cancel();
        _share = null;
        return;
      }
      setState(() {
        _a = a;
        _gone = false;
        _loadFailed = false;
      });
      _syncSharing(a);
      _autoRead(a);
    } catch (_) {
      // Keep showing the last good data; only show the retry screen if we never had any.
      if (mounted && _a == null) setState(() => _loadFailed = true);
    }
  }

  /// While travelling (journey started, not yet checked in) share position every 20 s —
  /// only while this screen is open, never in the background.
  void _syncSharing(Json a) {
    final tr = a['tracking'] as Json?;
    final travelling = tr != null && tr['arrived'] != true && (a['job'] as Json)['status'] == 'assigned';
    if (travelling && _share == null) {
      _share = Timer.periodic(const Duration(seconds: 20), (_) async {
        final p = await LocationService.quiet();
        if (p != null) {
          try {
            await state.api.sendLocation(widget.assignmentId, p.latitude, p.longitude);
          } catch (_) {}
        }
      });
    } else if (!travelling) {
      _share?.cancel();
      _share = null;
    }
  }

  Future<void> _run(Future<void> Function() fn) async {
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      await fn();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final l = L.of(context);
    final r = await showFinishWorkSheet(context);
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final sent = await Outbox.instance.done(widget.assignmentId, r.photos, r.note);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: sent ? BC.money : BC.ink,
        content: Text(sent ? l.finishSentWaiting : l.savedDoneOffline, style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white)),
      ));
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.withdrawHireTitle),
        content: Text(l.withdrawHireBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), style: FilledButton.styleFrom(backgroundColor: BC.danger), child: Text(l.withdrawHireConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await state.api.withdrawHire(widget.assignmentId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dispute() async {
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
    if (ok != true || text.length < 5 || !mounted) return;
    await _run(() => state.api.workerDispute(widget.assignmentId, text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: BC.ink, content: Text(l.reportedSnack, style: const TextStyle(fontSize: 15, color: Colors.white))));
  }

  Future<void> _startJourney() => _run(() async {
        final p = await LocationService.get(context, precise: false);
        await state.api.startJourney(widget.assignmentId, p?.latitude, p?.longitude);
      });

  /// Customer's 4-digit start code: checked online first (wrong -> try again inside the sheet); with no network the
  /// code is kept and verified when the check-in syncs. Returns null when the worker closed the sheet.
  Future<StartCodeResult?> _askCode() => showStartCodeSheet(context, submit: (c) => state.api.startWork(widget.assignmentId, code: c));

  /// Start-code state of this hire (null = no code involved): needed | locked | pending | failed | verified.
  String? get _codeState => _a?['start_code_state'] as String?;

  /// Re-enter the code after an offline check-in was wrong / is still pending (needs a connection).
  Future<void> _enterCode() async {
    final l = L.of(context);
    final r = await _askCode();
    if (r == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: r.offline ? BC.ink : BC.money,
        content: Text(r.offline ? l.startCodeOfflineSaved : l.startCodeVerified, style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white))));
    await _load();
  }

  Future<void> _mark(String kind) async {
    final l = L.of(context);
    String? code;
    var codeOffline = false;
    if (kind == 'in' && (_codeState == 'needed')) {
      final r = await _askCode();
      if (r == null || !mounted) return;
      code = r.code;
      codeOffline = r.offline;
    }
    setState(() => _busy = true);
    try {
      String? selfie;
      if (kind == 'in') {
        selfie = await pickPhoto(context, cameraOnly: true);
        if (selfie == null) return;
        try {
          selfie = (await state.api.upload('selfie', selfie))['key'] as String;
        } on ApiException catch (e) {
          if (!e.isNetwork) rethrow; // offline: keep the local path; attendance still recorded
        }
      }
      if (!mounted) return;
      final pos = await LocationService.get(context);
      if (pos == null) return; // LocationService already told the user what to fix
      final sent = await Outbox.instance.attendance({'assignment_id': widget.assignmentId, 'kind': kind, 'lat': pos.latitude,
        'lng': pos.longitude, 'selfie_key': selfie, if (code != null) 'start_code': code});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: sent ? BC.money : BC.ink,
        content: Text(sent ? (kind == 'in' ? l.checkedIn : l.checkedOut) : (codeOffline ? l.startCodeOfflineSaved : l.savedOffline),
            style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white)),
      ));
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final a = _a;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.myWork, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_headline.isNotEmpty) ReadButton(text: _headline, lang: state.language ?? 'hi'),
          IconButton(tooltip: l.wkHelpTitle, icon: const Icon(Icons.support_agent_rounded), onPressed: () => openHelp(context, state)),
          const SizedBox(width: 4),
        ],
      ),
      body: _gone
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.work_off_rounded, size: 56, color: BC.inkFaint),
                  const SizedBox(height: 12),
                  Text(l.hireEndedWorker, textAlign: TextAlign.center, style: context.tt.bodyLarge),
                  const SizedBox(height: 16),
                  SecondaryButton(label: l.ok, expand: false, onPressed: () => Navigator.of(context).maybePop()),
                ]),
              ),
            )
          : a != null
          ? RefreshIndicator(color: BC.brand, onRefresh: _load, child: _body(l, a))
          : _loadFailed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.wifi_off_rounded, size: 56, color: BC.inkFaint),
                      const SizedBox(height: 12),
                      Text(l.errorNetwork, textAlign: TextAlign.center, style: context.tt.bodyLarge),
                      const SizedBox(height: 16),
                      SecondaryButton(
                          label: l.retry,
                          icon: Icons.refresh_rounded,
                          expand: false,
                          onPressed: () {
                            setState(() => _loadFailed = false);
                            _load();
                          }),
                    ]),
                  ),
                )
              : const Center(child: CircularProgressIndicator(color: BC.brand)),
    );
  }

  Widget _body(L l, Json a) {
    final job = a['job'] as Json;
    final status = job['status'] as String;
    final pay = a['payment'] as Json?;
    final refix = a['kind'] == 'refix'; // free warranty visit: no escrow, no rating
    final escrow = pay?['escrow_state'] as String? ?? (refix ? 'free' : 'created');
    final codeState = a['start_code_state'] as String?;
    final att = (a['attendance'] as List).cast<Json>();
    final open = att.where((x) => x['out'] == null).isNotEmpty;
    final rated = (a['ratings'] as Map)['worker_to_customer'] != null;
    final tr = a['tracking'] as Json?;
    final jLat = (job['lat'] as num).toDouble(), jLng = (job['lng'] as num).toDouble();
    final km = distanceFromMe(jLat, jLng);

    String? stepTitle, stepSub;
    Widget step({required IconData icon, required Color color, required String title, String? sub, List<Widget> actions = const []}) {
      stepTitle = title;
      stepSub = sub;
      return Container(
          padding: const EdgeInsets.all(BC.padLg),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(BC.rMd), border: Border.all(color: color.withValues(alpha: 0.3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconBadge(icon, color: color, size: 48, solid: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge),
                  if (sub != null) Text(sub, maxLines: 4, overflow: TextOverflow.ellipsis, style: BC.subtle),
                ]),
              ),
            ]),
            for (final w in actions) ...[const SizedBox(height: 14), w],
          ]),
        );
    }

    late final Widget next;
    if (status == 'disputed') {
      next = step(icon: Icons.gavel_rounded, color: BC.danger, title: l.statusDisputed, sub: l.disputeOpenWorker);
    } else if (escrow == 'created') {
      next = step(icon: Icons.hourglass_top_rounded, color: BC.pendingInk, title: l.waitingForPayment, sub: l.waitingForPaymentSub);
    } else if (status == 'assigned' && tr == null) {
      next = step(icon: Icons.two_wheeler_rounded, color: BC.info, title: l.customerPaidGo, sub: l.customerPaidGoSub, actions: [
        PrimaryButton(big: true, busy: _busy, onPressed: _startJourney, icon: Icons.navigation_rounded, label: l.imOnMyWay),
      ]);
    } else if (status == 'assigned' && !open) {
      next = step(
        icon: Icons.near_me_rounded,
        color: BC.info,
        title: l.sharingLocation,
        sub: tr?['eta_min'] != null && tr?['arrived'] != true ? l.distanceEta((tr!['distance_km'] as num).toStringAsFixed(1), tr['eta_min'] as int) : l.reachedSite,
        actions: [
          if (codeState == 'needed' || codeState == 'locked') _codeBanner(l, a),
          PrimaryButton(big: true, color: BC.money, busy: _busy, onPressed: codeState == 'locked' ? null : () => _mark('in'), icon: Icons.login_rounded, label: l.arrivedCheckIn),
        ],
      );
    } else if (status == 'assigned' || status == 'in_progress') {
      final done = a['worker_done_at'] != null;
      final rework = a['rework_open'] == true;
      final queued = Outbox.instance.hasPendingFor('done', widget.assignmentId);
      final hoursLeft = hoursUntil(a['auto_confirm_at'] as String?);
      next = step(
        icon: rework ? Icons.replay_rounded : (done ? Icons.hourglass_bottom_rounded : Icons.construction_rounded),
        color: rework ? BC.danger : (done ? BC.pendingInk : BC.money),
        title: rework ? l.reworkCardTitle : (done ? l.waitingCustomerConfirm : l.workInProgress),
        sub: rework ? l.reworkCardSub : (done ? l.waitingCustomerConfirmSub : l.attendanceHint),
        actions: [
          if (codeState == 'pending' || codeState == 'failed' || codeState == 'locked' || codeState == 'needed') ...[
            _codeBanner(l, a),
            if (codeState == 'pending' || codeState == 'failed' || (codeState == 'needed' && open)) PrimaryButton(big: true, color: BC.money, onPressed: _busy ? null : _enterCode, icon: Icons.password_rounded, label: l.startCodeEnterAgain),
          ],
          if (done && ((a['proof_photos'] as List?) ?? const []).isNotEmpty) ThumbRow((a['proof_photos'] as List).cast<String>()),
          if (done && hoursLeft != null) InfoBanner(icon: Icons.timer_rounded, color: BC.info, text: l.autoReleaseWorker(hoursLeft)),
          if (bigText(context, 1.2))
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PrimaryButton(
                big: true,
                color: BC.money,
                onPressed: _busy || open || codeState == 'locked' ? null : () => _mark('in'),
                icon: Icons.login_rounded,
                label: l.checkIn,
              ),
              const SizedBox(height: 10),
              PrimaryButton(
                big: true,
                color: BC.ink,
                onPressed: _busy || !open ? null : () => _mark('out'),
                icon: Icons.logout_rounded,
                label: l.checkOut,
              ),
            ])
          else
            Row(children: [
              Expanded(child: PrimaryButton(
                big: true,
                color: BC.money,
                onPressed: _busy || open || codeState == 'locked' ? null : () => _mark('in'),
                icon: Icons.login_rounded,
                label: l.checkIn,
              )),
              const SizedBox(width: 10),
              Expanded(child: PrimaryButton(
                big: true,
                color: BC.ink,
                onPressed: _busy || !open ? null : () => _mark('out'),
                icon: Icons.logout_rounded,
                label: l.checkOut,
              )),
            ]),
          if (rework)
            PrimaryButton(big: true, color: BC.danger, busy: _busy, onPressed: _finish, icon: Icons.task_alt_rounded, label: l.doneAgain)
          else if (!done && !queued && !(codeState != null && codeState != 'verified'))
            SecondaryButton(onPressed: _busy ? null : _finish, icon: Icons.task_alt_rounded, label: l.workFinished),
          if (queued) InfoBanner(icon: Icons.cloud_upload_outlined, color: BC.pendingInk, text: l.savedDoneOffline),
        ],
      );
    } else if (refix && status == 'completed') {
      next = step(icon: Icons.build_circle_rounded, color: BC.money, title: l.refixDoneTitle, sub: l.refixDoneSub);
    } else if (status == 'completed' && escrow == 'held') {
      next = step(icon: Icons.star_half_rounded, color: BC.brand, title: l.waitingForRating, sub: l.speechHeld(inr(pay?['worker_payout_inr'] as num?)));
    } else {
      next = step(icon: Icons.payments_rounded, color: BC.money, title: l.paymentReceived, sub: l.escrowReleased(inr(pay?['worker_payout_inr'] as num?)));
    }

    _headline = '${stepTitle ?? ''}. ${stepSub ?? ''}. ${inr(a['price_inr'] as num)}. ${job['locality']}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _autoRead(a);
    });
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      const PendingChip(),
      if (refix) ...[
        _RefixCard(reason: (a['refix'] as Map?)?['reason'] as String?),
        const SizedBox(height: 12),
      ],
      next,
      if (a['rework_open'] == true && a['rework'] is Map) ...[const SizedBox(height: 12), _ReworkCard(rework: (a['rework'] as Map).cast<String, dynamic>(), round: (a['rework_count'] as num?)?.toInt() ?? 1, total: (((a['rework_count'] as num?) ?? 0) + ((a['rework_left'] as num?) ?? 0)).toInt())],
      if (status == 'completed' && a['auto_confirmed'] == true && escrow == 'released') ...[const SizedBox(height: 12), InfoBanner(icon: Icons.timer_rounded, color: BC.money, text: l.autoPaidWorker)],
      const SizedBox(height: 12),
      AppCard(
        padding: const EdgeInsets.all(BC.pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)])),
            const SizedBox(width: 8),
            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(refix ? l.refixBadge : inr(a['price_inr'] as num), maxLines: 1, style: context.tt.displaySmall))),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.place_rounded, color: BC.brand, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(job['address'] as String, style: context.tt.titleMedium)),
          ]),
          if (km != null) Padding(padding: const EdgeInsets.only(top: 2, left: 30), child: Text(l.kmFromYou(km), style: BC.subtle)),
          const SizedBox(height: 12),
          JobMap(
            lat: jLat,
            lng: jLng,
            exact: true,
            me: LocationService.last == null ? null : (LocationService.last!.latitude, LocationService.last!.longitude),
            onDirections: () => LocationService.directions(jLat, jLng),
          ),
          if (a['customer_name'] != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.person_rounded, color: BC.inkFaint, size: 22),
              const SizedBox(width: 8),
              Expanded(child: Text(a['customer_name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyLarge)),
            ]),
          ],
          if (pay != null) EscrowLine(state: escrow, amount: pay['worker_payout_inr'] as num),
        ]),
      ),
      if (att.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionHeader(l.attendance),
        for (final x in att.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                IconBadge(Icons.how_to_reg_rounded, color: x['geofence_ok'] == true ? BC.money : BC.pendingInk, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_hm(x['in'] as String)} → ${x['out'] == null ? '…' : _hm(x['out'] as String)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium!.copyWith(fontFeatures: BC.tabular)),
                    Text(_day(x['in'] as String), style: BC.subtle),
                    if (x['offline'] == true || x['geofence_ok'] != true || x['code_status'] == 'pending' || x['code_status'] == 'failed')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          if (x['offline'] == true) StatusPill(label: l.syncedLater, color: BC.info, bg: BC.infoSoft),
                          if (x['code_status'] == 'pending') StatusPill(label: l.startCodePendingPill, color: BC.pendingInk, bg: BC.pendingSoft, icon: Icons.password_rounded),
                          if (x['code_status'] == 'failed') StatusPill(label: l.startCodeFailedPill, color: BC.danger, bg: BC.danger.withValues(alpha: 0.1), icon: Icons.password_rounded),
                          if (x['geofence_ok'] != true) StatusPill(label: l.awayFromSite, color: BC.pendingInk, bg: BC.pendingSoft),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
      ],
      if (((a['timeline'] as List?) ?? const []).isNotEmpty) ...[
        const SizedBox(height: 12),
        CompletionTimeline(events: (a['timeline'] as List).cast<Json>()),
      ],
      const SizedBox(height: 12),
      if (status != 'completed')
        SecondaryButton(
          onPressed: () => openChat(context, state, jobId: job['id'] as String, withUser: job['customer_id'] as String? ?? '', title: l.chatWithCustomer),
          icon: Icons.chat_bubble_outline_rounded,
          label: l.chatWithCustomer,
        ),
      if (escrow == 'held' && (a['worker_done_at'] != null || a['rework_open'] == true || status == 'completed') && status != 'disputed')
        TextButton.icon(
          onPressed: _busy ? null : _dispute,
          icon: const Icon(Icons.report_gmailerrorred_rounded, color: BC.danger),
          label: Text(l.workerDisputeBtn, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: BC.danger)),
        ),
      TextButton.icon(
        onPressed: () => openHelp(context, state, problem: true),
        icon: const Icon(Icons.support_agent_rounded),
        label: Text(l.wkHelpReport, maxLines: 2, textAlign: TextAlign.center),
      ),
      if (status == 'assigned' && a['started_at'] == null)
        TextButton(
          onPressed: _busy ? null : _withdraw,
          child: Text(l.withdrawHireBtn, style: const TextStyle(color: BC.inkSoft)),
        ),
      if (status == 'completed' && !rated) _RateCustomer(state: state, assignmentId: widget.assignmentId, onDone: _load),
      if (status == 'completed' && rated) InfoBanner(icon: Icons.thumb_up_alt_rounded, color: BC.money, text: l.thanksForRating),
    ]);
  }

  /// Start-code hint for the worker: ask for it / locked / saved offline / wrong offline.
  Widget _codeBanner(L l, Json a) {
    final st = a['start_code_state'] as String?;
    if (st == 'locked') {
      final until = DateTime.tryParse('${a['start_code_locked_until']}')?.toLocal();
      final mins = until == null ? 10 : (until.difference(DateTime.now()).inSeconds / 60).ceil().clamp(1, 10);
      return InfoBanner(icon: Icons.lock_clock_rounded, color: BC.danger, text: l.startCodeLockedWorker(mins));
    }
    if (st == 'pending') return InfoBanner(icon: Icons.cloud_upload_outlined, color: BC.pendingInk, text: l.startCodePending);
    if (st == 'failed') return InfoBanner(icon: Icons.error_outline_rounded, color: BC.danger, text: l.startCodeFailed);
    return InfoBanner(icon: Icons.password_rounded, color: BC.info, text: l.startCodeNeeded);
  }

  // Times shown in the phone's local time zone (stored as UTC).
  String _hm(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _day(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.day}/${d.month}/${d.year}';
  }
}

/// "Warranty re-fix" badge + what the customer reported (a free visit for a job this worker did earlier).
class _RefixCard extends StatelessWidget {
  const _RefixCard({this.reason});
  final String? reason;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return AppCard(
      color: BC.infoSoft,
      borderColor: BC.info.withValues(alpha: 0.4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.build_circle_rounded, color: BC.info),
          const SizedBox(width: 8),
          Expanded(child: Text(l.refixBadge, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium!.copyWith(color: BC.info))),
        ]),
        const SizedBox(height: 4),
        Text(l.refixFreeVisit, style: BC.subtle),
        if (reason != null && reason!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(l.refixReasonLabel(reason!), maxLines: 5, overflow: TextOverflow.ellipsis, style: context.tt.bodyLarge),
        ],
      ]),
    );
  }
}

/// Red card: exactly what the customer said was wrong (reasons, note, photos).
class _ReworkCard extends StatelessWidget {
  const _ReworkCard({required this.rework, required this.round, required this.total});
  final Json rework;
  final int round, total;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final reasons = ((rework['reasons'] as List?) ?? const []).cast<String>();
    final note = (rework['note'] as String?) ?? '';
    final photos = ((rework['photos'] as List?) ?? const []).cast<String>();
    return Container(
      padding: const EdgeInsets.all(BC.pad),
      decoration: BoxDecoration(color: BC.danger.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(BC.rMd), border: Border.all(color: BC.danger.withValues(alpha: 0.45))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.report_rounded, color: BC.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(l.reworkCustomerSays, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: BC.danger))),
          StatusPill(label: l.reworkCardRound(round, total), color: BC.danger, bg: Colors.white),
        ]),
        const SizedBox(height: 10),
        ReasonChips(reasons),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(note, style: const TextStyle(fontSize: 16, height: 1.4, color: BC.ink)),
        ],
        if (photos.isNotEmpty) ...[
          const SizedBox(height: 10),
          ThumbRow(photos, size: 80),
        ],
      ]),
    );
  }
}

class _RateCustomer extends StatefulWidget {
  const _RateCustomer({required this.state, required this.assignmentId, required this.onDone});
  final AppState state;
  final String assignmentId;
  final Future<void> Function() onDone;
  @override
  State<_RateCustomer> createState() => _RateCustomerState();
}

class _RateCustomerState extends State<_RateCustomer> {
  int _clarity = 0, _paid = 0;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.state.api.rateCustomer(widget.assignmentId, _clarity, _paid, null);
      await widget.onDone();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return AppCard(
      padding: const EdgeInsets.all(BC.padLg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.rateCustomerTitle, style: context.tt.titleLarge),
        const SizedBox(height: 14),
        Text(l.rateClarity, style: context.tt.titleSmall),
        const SizedBox(height: 4),
        StarInput(value: _clarity, onChanged: (v) => setState(() => _clarity = v)),
        const SizedBox(height: 12),
        Text(l.rateTimelyPayment, style: context.tt.titleSmall),
        const SizedBox(height: 4),
        StarInput(value: _paid, onChanged: (v) => setState(() => _paid = v)),
        const SizedBox(height: 16),
        PrimaryButton(onPressed: _clarity == 0 || _paid == 0 ? null : _submit, busy: _busy, label: l.submit),
      ]),
    );
  }
}

/// "₹1,800 held safely until work is done and rated" — shared by worker + customer screens.
class EscrowLine extends StatelessWidget {
  const EscrowLine({super.key, required this.state, required this.amount});
  final String state;
  final num amount;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final (text, color, icon) = switch (state) {
      'held' => (l.escrowHeld(inr(amount)), BC.pendingInk, Icons.lock_rounded),
      'released' => (l.escrowReleased(inr(amount)), BC.money, Icons.check_circle_rounded),
      'refunded' => (l.escrowRefunded, BC.closed, Icons.undo_rounded),
      'split' => (l.escrowSplit, BC.info, Icons.call_split_rounded),
      _ => (l.escrowCreated, BC.inkSoft, Icons.hourglass_top_rounded),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: context.tt.labelLarge!.copyWith(color: color, height: 1.4))),
      ]),
    );
  }
}
