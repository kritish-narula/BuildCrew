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
  Timer? _refresh, _share;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 6), (_) => _load());
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
      setState(() => _a = a);
      _syncSharing(a);
    } catch (_) {}
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
        content: Text(sent ? (kind == 'in' ? l.checkedIn : l.checkedOut) : l.savedOffline, style: const TextStyle(fontSize: 16)),
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
      appBar: AppBar(title: Text(l.myWork)),
      body: a == null ? const Center(child: CircularProgressIndicator(color: BC.brand)) : RefreshIndicator(color: BC.brand, onRefresh: _load, child: _body(l, a)),
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
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: color.withValues(alpha: 0.35))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              CircleAvatar(radius: 26, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 28)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  if (sub != null) Text(sub, style: const TextStyle(color: BC.inkSoft, fontSize: 15)),
                ]),
              ),
            ]),
            for (final w in actions) ...[const SizedBox(height: 12), w],
          ]),
        );

    late final Widget next;
    if (status == 'disputed') {
      next = step(icon: Icons.gavel_rounded, color: BC.danger, title: l.statusDisputed, sub: l.disputeOpenWorker);
    } else if (escrow == 'created') {
      next = step(icon: Icons.hourglass_top_rounded, color: const Color(0xFF92400E), title: l.waitingForPayment, sub: l.waitingForPaymentSub);
    } else if (status == 'assigned' && tr == null) {
      next = step(icon: Icons.two_wheeler_rounded, color: BC.info, title: l.customerPaidGo, sub: l.customerPaidGoSub, actions: [
        FilledButton.icon(onPressed: _busy ? null : _startJourney, icon: const Icon(Icons.navigation_rounded), label: Text(l.imOnMyWay)),
      ]);
    } else if (status == 'assigned' && !open) {
      next = step(
        icon: Icons.near_me_rounded,
        color: BC.info,
        title: l.sharingLocation,
        sub: tr?['eta_min'] != null && tr?['arrived'] != true ? l.distanceEta((tr!['distance_km'] as num).toStringAsFixed(1), tr['eta_min'] as int) : l.reachedSite,
        actions: [
          FilledButton.icon(
            onPressed: _busy ? null : () => _mark('in'),
            style: FilledButton.styleFrom(backgroundColor: BC.money),
            icon: const Icon(Icons.login_rounded),
            label: Text(l.arrivedCheckIn),
          ),
        ],
      );
    } else if (status == 'assigned' || status == 'in_progress') {
      final done = a['worker_done_at'] != null;
      next = step(
        icon: done ? Icons.hourglass_bottom_rounded : Icons.construction_rounded,
        color: done ? const Color(0xFF92400E) : BC.money,
        title: done ? l.waitingCustomerConfirm : l.workInProgress,
        sub: done ? l.waitingCustomerConfirmSub : l.attendanceHint,
        actions: [
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || open ? null : () => _mark('in'),
                style: FilledButton.styleFrom(backgroundColor: BC.money),
                icon: const Icon(Icons.login_rounded),
                label: Text(l.checkIn),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || !open ? null : () => _mark('out'),
                style: FilledButton.styleFrom(backgroundColor: BC.ink),
                icon: const Icon(Icons.logout_rounded),
                label: Text(l.checkOut),
              ),
            ),
          ]),
          if (!done)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(() => state.api.markDone(widget.assignmentId)),
              icon: const Icon(Icons.task_alt_rounded),
              label: Text(l.workFinished),
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
      const SizedBox(height: 14),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)])),
              Text(inr(a['price_inr'] as num), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.place_rounded, color: BC.brand),
              const SizedBox(width: 6),
              Expanded(child: Text(job['address'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            ]),
            if (km != null) Padding(padding: const EdgeInsets.only(top: 4, left: 30), child: Text(l.kmFromYou(km), style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600))),
            const SizedBox(height: 12),
            JobMap(
              lat: jLat,
              lng: jLng,
              exact: true,
              me: LocationService.last == null ? null : (LocationService.last!.latitude, LocationService.last!.longitude),
              onDirections: () => LocationService.directions(jLat, jLng),
            ),
            if (a['customer_name'] != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                const Icon(Icons.person_rounded, color: BC.inkSoft),
                const SizedBox(width: 6),
                Text(a['customer_name'] as String, style: const TextStyle(fontSize: 16)),
              ]),
            ],
            if (pay != null) EscrowLine(state: escrow, amount: pay['worker_payout_inr'] as num),
          ]),
        ),
      ),
      if (att.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(l.attendance, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final x in att.reversed)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(Icons.how_to_reg_rounded, color: x['geofence_ok'] == true ? BC.money : BC.pending),
              title: Text('${_hm(x['in'] as String)} → ${x['out'] == null ? '…' : _hm(x['out'] as String)}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
              subtitle: Text(_day(x['in'] as String)),
              trailing: Wrap(spacing: 6, children: [
                if (x['offline'] == true) StatusPill(label: l.syncedLater, color: BC.info, bg: BC.infoSoft),
                if (x['geofence_ok'] != true) StatusPill(label: l.awayFromSite, color: const Color(0xFF92400E), bg: BC.pendingSoft),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 10),
      if (status != 'completed')
        OutlinedButton.icon(
          onPressed: () => openChat(context, state, jobId: job['id'] as String, withUser: job['customer_id'] as String? ?? '', title: l.chatWithCustomer),
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          label: Text(l.chatWithCustomer),
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
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.rateCustomerTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(l.rateClarity, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          StarInput(value: _clarity, onChanged: (v) => setState(() => _clarity = v)),
          const SizedBox(height: 8),
          Text(l.rateTimelyPayment, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          StarInput(value: _paid, onChanged: (v) => setState(() => _paid = v)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _clarity == 0 || _paid == 0
                ? null
                : () async {
                    try {
                      await widget.state.api.rateCustomer(widget.assignmentId, _clarity, _paid, null);
                      await widget.onDone();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
            child: Text(l.submit),
          ),
        ]),
      ),
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
      'held' => (l.escrowHeld(inr(amount)), const Color(0xFF92400E), Icons.lock_rounded),
      'released' => (l.escrowReleased(inr(amount)), BC.money, Icons.check_circle_rounded),
      'refunded' => (l.escrowRefunded, BC.closed, Icons.undo_rounded),
      'split' => (l.escrowSplit, BC.info, Icons.call_split_rounded),
      _ => (l.escrowCreated, BC.inkSoft, Icons.hourglass_top_rounded),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15))),
      ]),
    );
  }
}
