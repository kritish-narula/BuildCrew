import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/app_state.dart';
import '../../core/outbox.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/maps.dart';
import '../../widgets/media.dart';
import '../common/chat.dart';
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
  Timer? _refresh, _share;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!_busy) _load();
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _share?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final all = await state.api.assignments();
      final a = all.firstWhere((x) => x['id'] == widget.assignmentId);
      if (!mounted) return;
      setState(() {
        _a = a;
        _loadFailed = false;
      });
      _syncSharing(a);
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

  Future<void> _startJourney() => _run(() async {
        final p = await LocationService.get(context, precise: false);
        await state.api.startJourney(widget.assignmentId, p?.latitude, p?.longitude);
      });

  Future<void> _mark(String kind) async {
    final l = L.of(context);
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
        'lng': pos.longitude, 'selfie_key': selfie});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: sent ? BC.money : BC.ink,
        content: Text(sent ? (kind == 'in' ? l.checkedIn : l.checkedOut) : l.savedOffline, style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white)),
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
      appBar: AppBar(title: Text(l.myWork, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: a != null
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
    final escrow = pay?['escrow_state'] as String? ?? 'created';
    final att = (a['attendance'] as List).cast<Json>();
    final open = att.where((x) => x['out'] == null).isNotEmpty;
    final rated = (a['ratings'] as Map)['worker_to_customer'] != null;
    final tr = a['tracking'] as Json?;
    final jLat = (job['lat'] as num).toDouble(), jLng = (job['lng'] as num).toDouble();
    final km = distanceFromMe(jLat, jLng);

    Widget step({required IconData icon, required Color color, required String title, String? sub, List<Widget> actions = const []}) => Container(
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
          PrimaryButton(big: true, color: BC.money, busy: _busy, onPressed: () => _mark('in'), icon: Icons.login_rounded, label: l.arrivedCheckIn),
        ],
      );
    } else if (status == 'assigned' || status == 'in_progress') {
      final done = a['worker_done_at'] != null;
      next = step(
        icon: done ? Icons.hourglass_bottom_rounded : Icons.construction_rounded,
        color: done ? BC.pendingInk : BC.money,
        title: done ? l.waitingCustomerConfirm : l.workInProgress,
        sub: done ? l.waitingCustomerConfirmSub : l.attendanceHint,
        actions: [
          Row(children: [
            Expanded(
              child: PrimaryButton(
                big: true,
                color: BC.money,
                onPressed: _busy || open ? null : () => _mark('in'),
                icon: Icons.login_rounded,
                label: l.checkIn,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryButton(
                big: true,
                color: BC.ink,
                onPressed: _busy || !open ? null : () => _mark('out'),
                icon: Icons.logout_rounded,
                label: l.checkOut,
              ),
            ),
          ]),
          if (!done)
            SecondaryButton(
              onPressed: _busy ? null : () => _run(() => state.api.markDone(widget.assignmentId)),
              icon: Icons.task_alt_rounded,
              label: l.workFinished,
            ),
        ],
      );
    } else if (status == 'completed' && escrow == 'held') {
      next = step(icon: Icons.star_half_rounded, color: BC.brand, title: l.waitingForRating, sub: l.speechHeld(inr(pay?['worker_payout_inr'] as num?)));
    } else {
      next = step(icon: Icons.payments_rounded, color: BC.money, title: l.paymentReceived, sub: l.escrowReleased(inr(pay?['worker_payout_inr'] as num?)));
    }

    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      const PendingChip(),
      next,
      const SizedBox(height: 12),
      AppCard(
        padding: const EdgeInsets.all(BC.pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)])),
            const SizedBox(width: 8),
            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(inr(a['price_inr'] as num), maxLines: 1, style: context.tt.displaySmall))),
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
                    if (x['offline'] == true || x['geofence_ok'] != true)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          if (x['offline'] == true) StatusPill(label: l.syncedLater, color: BC.info, bg: BC.infoSoft),
                          if (x['geofence_ok'] != true) StatusPill(label: l.awayFromSite, color: BC.pendingInk, bg: BC.pendingSoft),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 12),
      if (status != 'completed')
        SecondaryButton(
          onPressed: () => openChat(context, state, jobId: job['id'] as String, withUser: job['customer_id'] as String? ?? '', title: l.chatWithCustomer),
          icon: Icons.chat_bubble_outline_rounded,
          label: l.chatWithCustomer,
        ),
      if (status == 'completed' && !rated) _RateCustomer(state: state, assignmentId: widget.assignmentId, onDone: _load),
      if (status == 'completed' && rated) InfoBanner(icon: Icons.thumb_up_alt_rounded, color: BC.money, text: l.thanksForRating),
    ]);
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
