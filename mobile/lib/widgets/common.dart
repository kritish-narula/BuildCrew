import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/speech.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';

/// Trade identity: every trade has ONE icon and ONE colour used everywhere, so a worker
/// recognises "plumbing work" from the picture before reading any word.
class TradeStyle {
  const TradeStyle(this.icon, this.color);
  final IconData icon;
  final Color color;

  static const _map = {
    'mason': TradeStyle(Icons.foundation, Color(0xFFB45309)),
    'plumber': TradeStyle(Icons.plumbing, Color(0xFF0369A1)),
    'electrician': TradeStyle(Icons.electrical_services, Color(0xFFCA8A04)),
    'carpenter': TradeStyle(Icons.carpenter, Color(0xFF7C2D12)),
    'painter': TradeStyle(Icons.format_paint, Color(0xFF7E22CE)),
    'helper': TradeStyle(Icons.handyman, Color(0xFF475569)),
  };
  static TradeStyle of(String code) => _map[code] ?? const TradeStyle(Icons.construction, BC.inkSoft);
}

String tradeLabel(L l, String code) => switch (code) {
      'mason' => l.tradeMason,
      'plumber' => l.tradePlumber,
      'electrician' => l.tradeElectrician,
      'carpenter' => l.tradeCarpenter,
      'painter' => l.tradePainter,
      _ => l.tradeHelper,
    };

String timeAgo(L l, DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 60) return l.agoMinutes(d.inMinutes.clamp(1, 59));
  if (d.inHours < 24) return l.agoHours(d.inHours);
  return l.agoDays(d.inDays);
}

class TradeChip extends StatelessWidget {
  const TradeChip(this.code, {super.key});
  final String code;
  @override
  Widget build(BuildContext context) {
    final s = TradeStyle.of(code);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      decoration: BoxDecoration(color: s.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 20, color: s.color),
        const SizedBox(width: 6),
        Text(tradeLabel(L.of(context), code),
            style: TextStyle(fontWeight: FontWeight.w700, color: s.color, fontSize: 15)),
      ]),
    );
  }
}

/// Round speaker button — reads [text] aloud in [lang]. Used next to anything a worker might
/// not be able to read comfortably.
class SpeakButton extends StatefulWidget {
  const SpeakButton({super.key, required this.text, required this.lang, this.size = 44});
  final String text, lang;
  final double size;
  @override
  State<SpeakButton> createState() => _SpeakButtonState();
}

class _SpeakButtonState extends State<SpeakButton> {
  bool _speaking = false;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: L.of(context).listen,
      child: InkResponse(
        radius: widget.size * 0.7,
        onTap: () async {
          setState(() => _speaking = true);
          await Speaker.instance.say(widget.text, widget.lang);
          if (mounted) setState(() => _speaking = false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(color: _speaking ? BC.brand : BC.brandSoft, shape: BoxShape.circle),
          child: Icon(_speaking ? Icons.graphic_eq : Icons.volume_up_rounded,
              color: _speaking ? Colors.white : BC.brandDark, size: widget.size * 0.52),
        ),
      ),
    );
  }
}

/// Colour-coded pill readable without reading (spec S6): amber = waiting, green = yes/money,
/// grey = closed, blue = in progress, red = problem.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, required this.bg, this.icon});
  final String label;
  final Color color, bg;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 16, color: color), const SizedBox(width: 6)],
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13)),
        ]),
      );
}

class ComingSoon extends StatelessWidget {
  const ComingSoon({super.key, required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 120,
            height: 120,
            decoration: const BoxDecoration(color: BC.brandSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 56, color: BC.brandDark),
          ),
          const SizedBox(height: 24),
          Text(l.comingSoon, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(l.comingSoonSub, textAlign: TextAlign.center, style: const TextStyle(color: BC.inkSoft, fontSize: 16)),
        ]),
      ),
    );
  }
}

void showError(BuildContext context, Object e) {
  final l = L.of(context);
  // Server errors arrive already translated into the user's language; we only fill gaps.
  final msg = switch (e) {
    ApiException(code: 'network') => l.errorNetwork,
    ApiException(code: 'err.otp_invalid', message: '') => l.errorGeneric,
    ApiException(:final message) when message.isNotEmpty => message,
    _ => l.errorGeneric,
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(fontSize: 16)),
    backgroundColor: BC.ink,
  ));
}

class DemoChip extends StatelessWidget {
  const DemoChip({super.key});
  @override
  Widget build(BuildContext context) => StatusPill(
      label: L.of(context).demoBanner, color: BC.info, bg: BC.infoSoft, icon: Icons.science_outlined);
}
