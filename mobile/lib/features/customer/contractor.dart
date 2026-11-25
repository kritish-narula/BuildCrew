import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';
import 'customer_home.dart' show bookingStatus;

/// True for a team job (a contractor hiring N workers per trade at a daily wage).
bool isTeamJob(Json j) => j['kind'] == 'team';

/// Site still needs the contractor (hiring, running) as opposed to finished / cancelled.
bool isActiveSite(Json j) => const ['open', 'bidding', 'assigned', 'in_progress'].contains(j['status']);

/// One team site on the contractor home / Team tab: how many of the team are hired (5/7), who is on site today,
/// applicants waiting, and the one thing to do next.
class TeamSiteCard extends StatelessWidget {
  const TeamSiteCard({super.key, required this.job, required this.onTap});
  final Json job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final team = (job['team'] as Json?) ?? const <String, dynamic>{};
    final filled = (team['filled'] as num?)?.toInt() ?? 0, total = (team['headcount'] as num?)?.toInt() ?? 0;
    final present = (team['present_today'] as num?)?.toInt() ?? 0;
    final bids = (job['bid_count'] as num?)?.toInt() ?? 0;
    final waiting = bids > filled ? bids - filled : 0;
    final lines = ((team['items'] as List?) ?? const []).cast<Json>();
    final (label, fg, bg, icon) = bookingStatus(l, job);
    final dueInr = (job['payment_due_inr'] as num?) ?? 0;
    final toSettle = (job['to_settle'] as num?)?.toInt() ?? 0;
    String? next;
    Color nextColor = BC.money;
    if (job['payment_state'] == 'created' && dueInr > 0) {
      next = l.teamPayNow(inr(dueInr));
      nextColor = BC.brandDark;
    } else if (toSettle > 0) {
      next = l.teamToSettle(toSettle);
    } else if (waiting > 0 && filled < total) {
      next = l.teamApplicants(waiting);
    }
    return AppCard(
      shadow: true,
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(l.teamFilled(filled, total), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge),
          ),
          const SizedBox(width: 8),
          Flexible(child: StatusPill(label: label, color: fg, bg: bg, icon: icon)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(value: total == 0 ? 0 : filled / total, minHeight: 8, backgroundColor: BC.line, color: BC.money),
        ),
        const SizedBox(height: 10),
        // "3 masons · 4 helpers": the lines of this job with their own fill state
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final line in lines)
            _LineChip(trade: line['trade'] as String, text: '${tradeCount(l, tradeLabel(l, line['trade'] as String), (line['headcount'] as num).toInt())} · ${line['filled']}/${line['headcount']}'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.place_outlined, size: 16, color: BC.inkSoft),
          const SizedBox(width: 3),
          Expanded(child: Text('${job['locality'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, fontSize: 14))),
        ]),
        const SizedBox(height: 2),
        ScheduleLine(iso: job['scheduled_for'] as String?, slot: job['time_slot'] as String?),
        if (filled > 0) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.how_to_reg_rounded, size: 16, color: present > 0 ? BC.money : BC.inkFaint),
            const SizedBox(width: 4),
            Expanded(
              child: Text(l.teamPresentCount(present, filled), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: present > 0 ? BC.money : BC.inkSoft)),
            ),
          ]),
        ],
        if (next != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: nextColor.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(child: Text(next, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: nextColor))),
              Icon(Icons.arrow_forward_rounded, size: 18, color: nextColor),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _LineChip extends StatelessWidget {
  const _LineChip({required this.trade, required this.text});
  final String trade, text;
  @override
  Widget build(BuildContext context) {
    final s = TradeStyle.of(trade);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: s.color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 16, color: s.color),
        const SizedBox(width: 5),
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: s.color))),
      ]),
    );
  }
}

/// "Team" tab (contractors only): every site, grouped by what needs attention.
class ContractorTeamTab extends StatelessWidget {
  const ContractorTeamTab({super.key, required this.jobs, required this.failed, required this.onReload, required this.onOpenJob, required this.onPostTeam});
  final List<Json>? jobs;
  final bool failed;
  final Future<void> Function() onReload;
  final ValueChanged<String> onOpenJob;
  final VoidCallback onPostTeam;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final all = jobs;
    Widget body;
    if (all == null) {
      body = failed ? Center(child: OutlinedButton(onPressed: onReload, child: Text(l.retry))) : const Center(child: CircularProgressIndicator(color: BC.brand));
    } else {
      final teams = all.where(isTeamJob).toList();
      final running = teams.where((j) => j['status'] == 'assigned' || j['status'] == 'in_progress').toList();
      final hiring = teams.where((j) => j['status'] == 'open' || j['status'] == 'bidding').toList();
      final past = teams.where((j) => !isActiveSite(j)).toList();
      List<Widget> section(String title, List<Json> list) => [
            if (list.isNotEmpty) SectionHeader(title, padding: const EdgeInsets.fromLTRB(2, 14, 2, 8)),
            for (final j in list) ...[TeamSiteCard(job: j, onTap: () => onOpenJob(j['id'] as String)), const SizedBox(height: 12)],
          ];
      body = RefreshIndicator(
        color: BC.brand,
        onRefresh: onReload,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          PrimaryButton(onPressed: onPostTeam, icon: Icons.group_add_rounded, label: l.postTeamJob),
          if (teams.isEmpty) EmptyState(icon: Icons.groups_outlined, text: l.teamNoSites),
          ...section(l.teamSectionRunning, running),
          ...section(l.teamSectionHiring, hiring),
          ...section(l.teamSectionPast, past),
        ]),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(l.navTeam)), body: body);
  }
}
