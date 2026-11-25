import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/error_text.dart';
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

// ------------------------------------------------------------------ buttons
/// Button label that can never wrap onto a second line: it shrinks slightly instead.
/// Use as the `child`/`label` of any Material button.
class BtnLabel extends StatelessWidget {
  const BtnLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false, textAlign: TextAlign.center));
}

/// Primary action: 52dp (56dp when [big] — worker-critical actions like "Check in").
/// While [busy] it keeps its colour and shows a spinner (a disabled grey button with a white
/// spinner is invisible).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.big = false,
    this.color,
    this.expand = true,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy, big, expand;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final h = big ? BC.tap : BC.btn;
    final bg = color ?? BC.brand;
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color,
        minimumSize: Size(expand ? double.infinity : 0, h),
        disabledBackgroundColor: busy ? bg : null,
        disabledForegroundColor: busy ? Colors.white : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        if (busy)
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        else if (icon != null)
          Icon(icon, size: 22),
        if (busy || icon != null) const SizedBox(width: 8),
        Flexible(child: BtnLabel(label)),
      ]),
    );
  }
}

/// Secondary / outlined action: 48dp, or 40dp when [compact].
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.compact = false,
    this.color,
    this.expand = true,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool compact, expand;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final h = compact ? BC.btnXs : BC.btnSm;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        minimumSize: Size(expand ? double.infinity : 0, h),
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        if (icon != null) ...[Icon(icon, size: compact ? 20 : 22), const SizedBox(width: 8)],
        Flexible(child: BtnLabel(label)),
      ]),
    );
  }
}

// ------------------------------------------------------------------ layout building blocks
/// The one card look: white, 1px warm border, 20 radius, 16 padding. Optional tap ripple.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(BC.pad),
    this.onTap,
    this.color = BC.card,
    this.borderColor = BC.line,
    this.radius = BC.rMd,
    this.shadow = false,
    this.clip = true,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color, borderColor;
  final double radius;
  final bool shadow, clip;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: borderColor));
    final inner = Padding(padding: padding, child: child);
    return DecoratedBox(
      decoration: shadow ? BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: BC.softShadow) : const BoxDecoration(),
      child: Material(
        color: color,
        shape: shape,
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        child: onTap == null ? inner : InkWell(onTap: onTap, child: inner),
      ),
    );
  }
}

/// Section title with an optional trailing widget (count, "See all", speaker…).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(2, 8, 2, 8)});
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
}

/// Soft rounded-square icon (used in list rows, settings, steps).
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.color = BC.brand, this.size = 44, this.solid = false});
  final IconData icon;
  final Color color;
  final double size;
  final bool solid;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: solid ? color : color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, color: solid ? Colors.white : color, size: size * 0.54),
      );
}

// ------------------------------------------------------------------ chips & pills
class TradeChip extends StatelessWidget {
  const TradeChip(this.code, {super.key});
  final String code;
  @override
  Widget build(BuildContext context) {
    final s = TradeStyle.of(code);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
      decoration: BoxDecoration(color: s.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 18, color: s.color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(tradeLabel(L.of(context), code),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.labelLarge!.copyWith(color: s.color, fontSize: 14)),
        ),
      ]),
    );
  }
}

/// Round speaker button — reads [text] aloud in [lang]. Used next to anything a worker might
/// not be able to read comfortably. Tap again while speaking to stop.
class SpeakButton extends StatefulWidget {
  const SpeakButton({super.key, required this.text, required this.lang, this.size = 40});
  final String text, lang;
  final double size;
  @override
  State<SpeakButton> createState() => _SpeakButtonState();
}

class _SpeakButtonState extends State<SpeakButton> {
  bool _speaking = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _tap() async {
    if (_speaking) {
      _reset?.cancel();
      setState(() => _speaking = false);
      await Speaker.instance.stop();
      return;
    }
    setState(() => _speaking = true);
    await Speaker.instance.say(widget.text, widget.lang);
    if (!mounted) return;
    // TTS returns as soon as speech STARTS; keep the "speaking" look for roughly its length.
    _reset?.cancel();
    final ms = math.min(30000, math.max(1500, widget.text.length * 70));
    _reset = Timer(Duration(milliseconds: ms), () {
      if (mounted) setState(() => _speaking = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hit = math.max(48.0, widget.size);
    return Semantics(
      button: true,
      label: L.of(context).listen,
      child: SizedBox(
        width: hit,
        height: hit,
        child: Center(
          child: InkResponse(
            radius: hit * 0.5,
            onTap: _tap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(color: _speaking ? BC.brand : BC.brandSoft, shape: BoxShape.circle),
              child: Icon(_speaking ? Icons.graphic_eq : Icons.volume_up_rounded,
                  color: _speaking ? Colors.white : BC.brandDark, size: widget.size * 0.54),
            ),
          ),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: color), const SizedBox(width: 5)],
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.labelMedium!.copyWith(color: color, fontWeight: FontWeight.w600)),
          ),
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
            width: 112,
            height: 112,
            decoration: const BoxDecoration(color: BC.brandSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 52, color: BC.brandDark),
          ),
          const SizedBox(height: 24),
          Text(l.comingSoon, textAlign: TextAlign.center, style: context.tt.headlineSmall),
          const SizedBox(height: 8),
          Text(l.comingSoonSub, textAlign: TextAlign.center, style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
        ]),
      ),
    );
  }
}

void showError(BuildContext context, Object e) {
  final l = L.of(context);
  // Server errors arrive already translated into the user's language; we only fill gaps
  // (the demo backend throws bare codes: map those to friendly text).
  final coded = e is ApiException && needsLocalText(e.message) ? errorMessageFor(l, e.code, e.message) : null;
  final msg = coded ?? switch (e) {
    ApiException(code: 'network') => l.errorNetwork,
    ApiException(code: 'err.otp_invalid', message: '') => l.errorGeneric,
    ApiException(:final message) when message.isNotEmpty => message,
    _ => l.errorGeneric,
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.white)),
      backgroundColor: BC.ink,
    ));
}

class DemoChip extends StatelessWidget {
  const DemoChip({super.key});
  @override
  Widget build(BuildContext context) => StatusPill(
      label: L.of(context).demoBanner, color: BC.info, bg: BC.infoSoft, icon: Icons.science_outlined);
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Column(children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(color: BC.closedSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 40, color: BC.inkFaint),
          ),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center, style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
        ]),
      );
}

/// Coloured info strip with an optional action — used for nudges, privacy notes, badges.
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.icon, required this.color, required this.text, this.action, this.onTap});
  final IconData icon;
  final Color color;
  final String text;
  final String? action;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: color.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r), side: BorderSide(color: color.withValues(alpha: 0.18))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: context.tt.labelLarge!.copyWith(color: color, fontWeight: FontWeight.w600, height: 1.4))),
              if (action != null) ...[
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(action!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tt.labelLarge!.copyWith(color: color, fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
                ),
              ],
            ]),
          ),
        ),
      );
}
