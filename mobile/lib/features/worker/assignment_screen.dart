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
  final _key = GlobalKey<State>();

  Future<Json> _load() async {
    final all = await widget.state.api.assignments();
    return all.firstWhere((a) => a['id'] == widget.assignmentId);
  }

  Future<void> _mark(String kind, Future<void> Function() reload) async {
    final l = L.of(context);
    setState(() => _busy = true);
    try {
      String? selfie;
      if (kind == 'in') {
        selfie = await pickPhoto(context, cameraOnly: true);
        if (selfie == null) return;
        try {
          selfie = (await widget.state.api.upload('selfie', selfie))['key'] as String;
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
      await reload();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.myWork)),
      body: AsyncList<Json>(
        key: _key,
        load: _load,
        builder: (ctx, a, reload) {
          final job = a['job'] as Json;
          final status = job['status'] as String;
          final pay = a['payment'] as Json?;
          final att = (a['attendance'] as List).cast<Json>();
          final open = att.where((x) => x['out'] == null).isNotEmpty;
          final rated = (a['ratings'] as Map)['worker_to_customer'] != null;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            const PendingChip(),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [for (final t in (job['trades'] as List).toSet()) TradeChip(t as String)]),
                  const SizedBox(height: 12),
                  Row(children: [
                    const Icon(Icons.place_rounded, color: BC.brand),
                    const SizedBox(width: 6),
                    Expanded(child: Text(job['address'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 12),
                  JobMap(
                    lat: (job['lat'] as num).toDouble(),
                    lng: (job['lng'] as num).toDouble(),
                    exact: true,
                    me: LocationService.last == null ? null : (LocationService.last!.latitude, LocationService.last!.longitude),
                    onDirections: () => LocationService.directions((job['lat'] as num).toDouble(), (job['lng'] as num).toDouble()),
                  ),
                  if (distanceFromMe((job['lat'] as num).toDouble(), (job['lng'] as num).toDouble()) case final km?)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(l.kmFromYou(km), style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
                    ),
                  if (a['customer_name'] != null) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.person_rounded, color: BC.inkSoft),
                      const SizedBox(width: 6),
                      Text(a['customer_name'] as String, style: const TextStyle(fontSize: 16)),
                    ]),
                  ],
                  const SizedBox(height: 14),
                  Text(inr(a['price_inr'] as num), style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
                  if (pay != null) EscrowLine(state: pay['escrow_state'] as String, amount: pay['worker_payout_inr'] as num),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            if (status == 'assigned' || status == 'in_progress') ...[
              Text(l.attendance, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy || open ? null : () => _mark('in', reload),
                    style: FilledButton.styleFrom(backgroundColor: BC.money),
                    icon: const Icon(Icons.login_rounded),
                    label: Text(l.checkIn),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy || !open ? null : () => _mark('out', reload),
                    style: FilledButton.styleFrom(backgroundColor: BC.ink),
                    icon: const Icon(Icons.logout_rounded),
                    label: Text(l.checkOut),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(l.attendanceHint, style: const TextStyle(color: BC.inkSoft)),
              const SizedBox(height: 10),
              for (final x in att.reversed)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(Icons.how_to_reg_rounded, color: x['geofence_ok'] == true ? BC.money : BC.pending),
                    title: Text('${_hm(x['in'] as String)} → ${x['out'] == null ? '…' : _hm(x['out'] as String)}',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
                    subtitle: Text((x['in'] as String).substring(0, 10)),
                    trailing: Wrap(spacing: 6, children: [
                      if (x['offline'] == true) StatusPill(label: l.syncedLater, color: BC.info, bg: BC.infoSoft),
                      if (x['geofence_ok'] != true) StatusPill(label: l.awayFromSite, color: const Color(0xFF92400E), bg: BC.pendingSoft),
                    ]),
                  ),
                ),
              if (status == 'assigned')
                OutlinedButton.icon(
                  onPressed: () async {
                    await widget.state.api.startWork(widget.assignmentId);
                    await reload();
                  },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(l.startWork),
                ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => openChat(context, widget.state, jobId: job['id'] as String, withUser: job['customer_id'] as String? ?? '', title: l.chatWithCustomer),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: Text(l.chatWithCustomer),
              ),
            ],
            if (status == 'completed' && !rated) _RateCustomer(state: widget.state, assignmentId: widget.assignmentId, onDone: reload),
            if (status == 'completed' && rated) InfoBanner(icon: Icons.thumb_up_alt_rounded, color: BC.money, text: l.thanksForRating),
            if (status == 'disputed') InfoBanner(icon: Icons.gavel_rounded, color: BC.danger, text: l.disputeOpenWorker),
          ]);
        },
      ),
    );
  }

  String _hm(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
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
