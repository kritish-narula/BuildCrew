import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'common.dart';
import 'media.dart';
import 'schedule.dart';

/// Worker feed / job detail: what a contractor's team job needs ("3 masons needed · ₹950/day · 5 days").
/// Only lines that still have room are listed; [trades] (the worker's own trades) puts his lines first.
class TeamNeedsBanner extends StatelessWidget {
  const TeamNeedsBanner({super.key, required this.team, this.trades = const [], this.max = 3});
  final Map? team;
  final List<String> trades;
  final int max;

  @override
  Widget build(BuildContext context) {
    final t = team;
    if (t == null) return const SizedBox.shrink();
    final l = L.of(context);
    final lines = (t['items'] as List).cast<Map>().where((i) => (i['filled'] as num) < (i['headcount'] as num)).toList()
      ..sort((a, b) => (trades.contains(b['trade']) ? 1 : 0).compareTo(trades.contains(a['trade']) ? 1 : 0));
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: BC.infoSoft, borderRadius: BorderRadius.circular(BC.r)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.groups_rounded, size: 20, color: BC.info),
          const SizedBox(width: 6),
          Expanded(
            child: Text(l.teamBadge((t['filled'] as num).toInt(), (t['headcount'] as num).toInt()), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BC.info, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 6),
        for (final i in lines.take(max))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(TradeStyle.of(i['trade'] as String).icon, size: 18, color: TradeStyle.of(i['trade'] as String).color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.teamLine(tradeCount(l, tradeLabel(l, i['trade'] as String), ((i['headcount'] as num) - (i['filled'] as num)).toInt()),
                      inr(i['daily_wage_inr'] as num), (i['days'] as num).toInt()),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: BC.ink, fontFeatures: BC.tabular),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}
