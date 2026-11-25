import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'media.dart';

/// "Fair Wage Shield" widgets. Both only inform, they never block anything.
/// Backend/demo JSON: `fair_range` {low, median, high, min_wage_total, est_days} on the worker job
/// detail, and `fair` {verdict: fair|below_min_wage|high, low, high, min_wage_total} on each bid.

/// Same threshold as backend `pricing.HIGH_FACTOR`.
const double _highFactor = 1.2;

/// "₹400 – ₹600"; a single value ("₹400") when low and high are the same (never "₹400 to ₹400").
String inrRange(num low, num high) => low >= high ? inr(low) : '${inr(low)} – ${inr(high)}';

String _daysText(num d) => d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);

/// Worker quote screen: fair range for THIS job + a gentle warning when [priceInr] is below the
/// minimum wage for the estimated days. Renders nothing when [fairRange] is null.
class FairPriceBanner extends StatelessWidget {
  const FairPriceBanner({super.key, required this.fairRange, this.priceInr});

  final Map<String, dynamic>? fairRange;
  final int? priceInr;

  @override
  Widget build(BuildContext context) {
    final f = fairRange;
    if (f == null) return const SizedBox.shrink();
    final low = f['low'] as num?;
    final high = f['high'] as num?;
    if (low == null || high == null) return const SizedBox.shrink();
    final minWage = (f['min_wage_total'] as num?) ?? 0;
    final days = (f['est_days'] as num?) ?? 1;
    final l = L.of(context);
    final price = priceInr;
    final below = price != null && price > 0 && price < minWage;
    final tooHigh = price != null && price > high * _highFactor;
    final okPrice = price != null && price > 0 && !below && !tooHigh;

    final Color bg, fg, border;
    final IconData icon;
    String? message;
    if (below) {
      bg = BC.pendingSoft;
      fg = BC.ink;
      border = BC.pending;
      icon = Icons.warning_amber_rounded;
      message = l.fairBelowMinWage(_daysText(days), inr(minWage));
    } else if (tooHigh) {
      bg = BC.infoSoft;
      fg = BC.ink;
      border = BC.info;
      icon = Icons.info_outline;
      message = l.fairYourPriceHigh;
    } else if (okPrice) {
      bg = BC.moneySoft;
      fg = BC.ink;
      border = BC.money;
      icon = Icons.verified_outlined;
      message = l.fairYourPriceOk;
    } else {
      bg = BC.brandSoft;
      fg = BC.ink;
      border = BC.line;
      icon = Icons.balance_outlined;
    }

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(BC.r),
        border: Border.all(color: border, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: border == BC.line ? BC.brand : border, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.fairRangeTitle, style: theme.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  l.fairRangeText(inrRange(low, high), _daysText(days)),
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
                if (message != null) ...[
                  const SizedBox(height: 8),
                  Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Customer bid card: "Fair price ✓" / "Below minimum wage ⚠" (+ note) / "Higher than usual".
/// Renders nothing when [fair] is null.
class FairBidBadge extends StatelessWidget {
  const FairBidBadge({super.key, required this.fair});

  final Map<String, dynamic>? fair;

  @override
  Widget build(BuildContext context) {
    final f = fair;
    if (f == null) return const SizedBox.shrink();
    final l = L.of(context);
    final verdict = f['verdict'] as String?;
    final Color bg, fg;
    final String label;
    switch (verdict) {
      case 'below_min_wage':
        bg = BC.pendingSoft;
        fg = const Color(0xFFB45309);
        label = l.fairBadgeBelow;
        break;
      case 'high':
        bg = BC.infoSoft;
        fg = BC.info;
        label = l.fairBadgeHigh;
        break;
      case 'fair':
        bg = BC.moneySoft;
        fg = BC.money;
        label = l.fairBadgeFair;
        break;
      default:
        return const SizedBox.shrink();
    }
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
    );
    if (verdict != 'below_min_wage') return Align(alignment: Alignment.centerLeft, child: chip);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        chip,
        const SizedBox(height: 4),
        Text(l.fairBelowNote, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: BC.inkSoft)),
      ],
    );
  }
}
