import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import 'customer_home.dart' show customerRoute;
import '../../widgets/media.dart';
import '../worker/assignment_screen.dart' show EscrowLine;
import '../worker/worker_shell.dart' show badgeLabel, initials;
import 'post_job.dart' show trades;

/// "Browse workers nearby" — verified workers, best rated first, filter by trade.
class BrowseWorkersScreen extends StatefulWidget {
  const BrowseWorkersScreen({super.key, required this.state});
  final AppState state;
  @override
  State<BrowseWorkersScreen> createState() => _BrowseWorkersScreenState();
}

class _BrowseWorkersScreenState extends State<BrowseWorkersScreen> {
  String? _trade;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.browseWorkers)),
      body: Column(children: [
        SizedBox(
          height: 56,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(selected: _trade == null, label: BtnLabel(l.all), onSelected: (_) => setState(() => _trade = null)),
            ),
            for (final t in trades)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  selected: _trade == t,
                  avatar: Icon(TradeStyle.of(t).icon, size: 18, color: TradeStyle.of(t).color),
                  label: Text(tradeLabel(l, t)),
                  onSelected: (_) => setState(() => _trade = t),
                ),
              ),
          ]),
        ),
        Expanded(
          child: AsyncList<List<Json>>(
            key: ValueKey(_trade),
            load: () => widget.state.api.browseWorkers(_trade),
            builder: (ctx, ws, _) => ws.isEmpty
                ? ListView(children: [EmptyState(icon: Icons.groups_rounded, text: l.noWorkers)])
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: ws.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final w = ws[i];
                      return Card(
                        child: ListTile(
                          minTileHeight: 84,
                          onTap: () => Navigator.of(context).push(customerRoute<void>(
                              builder: (_) => WorkerProfileScreen(state: widget.state, workerId: w['id'] as String))),
                          leading: Stack(children: [
                            CircleAvatar(radius: 26, backgroundColor: BC.brand,
                                child: Text(initials(w['name'] as String), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                            if (w['online'] == true)
                              const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 7, backgroundColor: Colors.white, child: CircleAvatar(radius: 5, backgroundColor: BC.money))),
                          ]),
                          title: Text(w['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                          subtitle: Text((w['trades'] as List).map((t) => tradeLabel(l, t as String)).join(', ')),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            StarBadge(w['rating'] as num),
                            Text(l.jobsDone(w['completed_jobs'] as int), style: const TextStyle(color: BC.inkSoft, fontSize: 13)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

class WorkerProfileScreen extends StatelessWidget {
  const WorkerProfileScreen({super.key, required this.state, required this.workerId});
  final AppState state;
  final String workerId;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: AsyncList<Json>(
        load: () => state.api.workerPublic(workerId),
        builder: (ctx, w, _) {
          final b = w['breakdown'] as Json;
          final history = (w['history'] as List).cast<Json>();
          return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
            Row(children: [
              CircleAvatar(radius: 40, backgroundColor: BC.brand,
                  child: Text(initials(w['name'] as String), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700))),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(w['name'] as String, style: Theme.of(context).textTheme.headlineSmall)),
                    if (w['verified'] == true) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified_rounded, color: BC.info)),
                  ]),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final t in w['trades'] as List) TradeChip(t as String)]),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Row(children: [
                    StarBadge(b['overall'] as num, big: true),
                    const SizedBox(width: 8),
                    Text(l.ratingFromJobs(b['count'] as int), style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 6),
                  RatingBars(breakdown: b),
                ]),
              ),
            ),
            for (final bd in (w['badges'] as List).cast<String>())
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InfoBanner(icon: Icons.workspace_premium_rounded, color: const Color(0xFFB45309),
                    text: badgeLabel(l, bd, b['overall'] as num, b['count'] as int)),
              ),
            const SizedBox(height: 16),
            if (history.isNotEmpty) Text(l.workHistory, style: Theme.of(context).textTheme.titleLarge),
            for (final h in history)
              Card(
                margin: const EdgeInsets.only(top: 10),
                clipBehavior: Clip.antiAlias,
                child: Row(children: [
                  AppImage(h['photo'] as String?, width: 96, height: 96),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      StarBadge(h['rating'] as num),
                      Text('${h['locality']} · ${h['date']}', style: const TextStyle(color: BC.inkSoft)),
                      if (h['comment'] != null) Text('“${h['comment']}”', style: const TextStyle(fontStyle: FontStyle.italic)),
                    ]),
                  ),
                ]),
              ),
          ]);
        },
      ),
    );
  }
}

/// C6 — receipts with escrow status.
class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.payments)),
      body: AsyncList<List<Json>>(
        load: state.api.payments,
        builder: (ctx, ps, _) => ps.isEmpty
            ? ListView(children: [EmptyState(icon: Icons.receipt_long_rounded, text: l.noPaymentsYet)])
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: ps.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) {
                  final p = ps[i];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text('${(p['trades'] as List).map((t) => tradeLabel(l, t as String)).join(', ')} · ${p['locality']}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                          Text(inr(p['amount_inr'] as num), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
                        ]),
                        if (p['worker_name'] != null) Text(p['worker_name'] as String, style: const TextStyle(color: BC.inkSoft)),
                        Text(l.feeIncluded(inr(p['platform_fee_inr'] as num)), style: const TextStyle(color: BC.inkSoft, fontSize: 13)),
                        EscrowLine(state: p['escrow_state'] as String, amount: p['escrow_state'] == 'held' ? p['amount_inr'] as num : p['worker_payout_inr'] as num),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
