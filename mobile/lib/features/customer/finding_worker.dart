import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/poller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../worker/worker_shell.dart' show initials;
import 'customer_home.dart' show customerRoute;
import 'customer_job.dart';

/// Expanding rings around a centre (radar / "live" dot). [t] is the animation value 0..1; [core] > 0 draws a solid centre dot.
class PulsePainter extends CustomPainter {
  PulsePainter(this.t, this.color, {this.rings = 3, this.core = 0});
  final double t;
  final Color color;
  final int rings;
  final double core;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = math.min(size.width, size.height) / 2;
    for (var i = 0; i < rings; i++) {
      final p = (t + i / rings) % 1.0;
      final r = maxR * (0.25 + 0.75 * p);
      final a = (1 - p) * 0.35;
      canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: a));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = color.withValues(alpha: math.min(1.0, a * 1.6))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    if (core > 0) canvas.drawCircle(c, core, Paint()..color = color);
  }

  @override
  bool shouldRepaint(PulsePainter old) => old.t != t || old.color != color || old.rings != rings || old.core != core;
}

/// Looping 0..1 animation that stands still (at [still]) when the phone asks for reduced motion.
mixin PulseMixin<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  bool? _reduced;
  double get still => 0.4;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce == _reduced) return;
    _reduced = reduce;
    if (reduce) {
      pulse.stop();
      pulse.value = still;
    } else {
      pulse.repeat();
    }
  }

  bool get reducedMotion => _reduced ?? false;

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }
}

/// Shown right after "Post job" (and from the Home card): the job is out, workers are being told, quotes fill in live.
/// Polls the job every 3 s (and asks [SyncService] for fast updates while it is open).
class FindingWorkerScreen extends StatefulWidget {
  const FindingWorkerScreen({super.key, required this.state, required this.jobId, this.notified});
  final AppState state;
  final String jobId;

  /// How many nearby workers were told about the job (null / 0: the line is left out).
  final int? notified;
  @override
  State<FindingWorkerScreen> createState() => _FindingWorkerScreenState();
}

class _FindingWorkerScreenState extends State<FindingWorkerScreen> with SingleTickerProviderStateMixin, PulseMixin<FindingWorkerScreen> {
  late final Poller _poller;
  Timer? _clock;
  Json? _job;
  final _seen = <String>{};
  bool _firstLoad = true, _leaving = false;
  int _tip = 0, _seq = 0, _applied = 0;
  final _opened = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
    _poller = Poller(const Duration(seconds: 3), _load)..start();
    _clock = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        if (t.tick % 6 == 0) _tip++;
      });
    });
  }

  @override
  void dispose() {
    _poller.dispose();
    _clock?.cancel();
    super.dispose();
  }

  List<Json> _bids(Json? job) => ((job?['bids'] as List?) ?? const []).cast<Json>().where((b) => b['status'] != 'withdrawn').toList();

  Future<void> _load() async {
    final seq = ++_seq;
    try {
      final j = await widget.state.api.customerJob(widget.jobId);
      if (!mounted || seq < _applied) return;
      _applied = seq;
      final bids = _bids(j);
      final fresh = bids.where((b) => !_seen.contains('${b['id']}')).toList();
      _seen.addAll(bids.map((b) => '${b['id']}'));
      final first = _firstLoad;
      _firstLoad = false;
      setState(() => _job = j);
      if (!first && fresh.isNotEmpty) _onNewQuote(fresh.first);
      final st = j['status'];
      if (st != 'open' && st != 'bidding') _openJob(); // hired, cancelled...: this screen has nothing more to show
    } catch (_) {
      // best-effort: keep what is on screen, the next tick tries again
    }
  }

  /// In-app banner + a buzz (the system notification comes from the SyncService, also when the app is in the background).
  void _onNewQuote(Json b) {
    HapticFeedback.mediumImpact();
    final l = L.of(context);
    final name = (((b['worker'] as Map?)?['name']) as String? ?? '').split(' ').first;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: BC.money,
        content: Text(l.fwNewQuote(name, inr(b['price_inr'] as num)), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: Colors.white)),
      ));
  }

  /// Open the quotes (the full job screen). This screen is replaced, so Back goes to Home.
  void _openJob() {
    if (_leaving || !mounted) return;
    _leaving = true;
    Navigator.of(context).pushReplacement(customerRoute<void>(builder: (_) => CustomerJobScreen(state: widget.state, jobId: widget.jobId)));
  }

  Duration _sincePosted() {
    final c = DateTime.tryParse('${_job?['created_at'] ?? ''}')?.toLocal();
    final now = DateTime.now();
    final d = c == null ? now.difference(_opened) : now.difference(c);
    return d.isNegative || d.inHours > 48 ? now.difference(_opened) : d;
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final job = _job;
    final bids = _bids(job);
    final direct = (job?['direct'] as Map?)?.cast<String, dynamic>();
    final directPending = direct != null && direct['state'] == 'pending';
    final directName = '${((direct?['worker'] as Map?)?['name']) ?? ''}'.split(' ').first;
    final notified = widget.notified ?? 0;
    final sub = directPending ? l.fwDirect(directName) : (notified > 0 ? l.fwNotified(notified) : null);
    final tips = [l.fwTip1, l.fwTip2, l.fwTip3];
    final tip = tips[_tip % tips.length];
    final quick = reducedMotion ? Duration.zero : const Duration(milliseconds: 350);

    return Scaffold(
      appBar: AppBar(title: Text(l.jobPosted, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Center(
            child: SizedBox(
              key: const ValueKey('radar'),
              width: 220,
              height: 220,
              child: AnimatedBuilder(
                animation: pulse,
                builder: (context, child) => CustomPaint(painter: PulsePainter(pulse.value, BC.brand), child: child),
                child: Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))]),
                    child: const Icon(Icons.location_on_rounded, color: BC.brand, size: 38),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(l.fwHeadline, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, height: 1.2)),
          if (sub != null) ...[
            const SizedBox(height: 8),
            Text(sub, key: const ValueKey('notifiedLine'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: BC.inkSoft, height: 1.35)),
          ],
          const SizedBox(height: 12),
          Center(child: StatusPill(key: const ValueKey('elapsed'), label: l.fwWaiting(mmss(_sincePosted().inSeconds)), color: BC.brandDark, bg: BC.brandSoft, icon: Icons.timer_outlined)),
          const SizedBox(height: 20),
          SectionHeader(l.fwQuotesTitle, padding: const EdgeInsets.fromLTRB(2, 0, 2, 8), trailing: bids.isEmpty ? null : StatusPill(label: '${bids.length}', color: BC.money, bg: BC.moneySoft)),
          if (bids.isEmpty)
            AppCard(
              key: const ValueKey('noQuotes'),
              child: Row(children: [
                const Icon(Icons.hourglass_top_rounded, color: BC.inkSoft),
                const SizedBox(width: 12),
                Expanded(child: Text(l.fwNoQuotes, style: const TextStyle(fontSize: 15, color: BC.inkSoft, height: 1.35))),
              ]),
            )
          else
            for (final b in bids)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TweenAnimationBuilder<double>(
                  key: ValueKey('quote${b['id']}'),
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: quick,
                  curve: Curves.easeOut,
                  builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 16), child: child)),
                  child: _QuoteTile(bid: b, onTap: _openJob),
                ),
              ),
          const SizedBox(height: 10),
          AppCard(
            color: BC.brandSoft,
            borderColor: BC.brandSoft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(children: [
                const Icon(Icons.lightbulb_outline_rounded, color: BC.brandDark),
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: quick,
                    child: Text(tip, key: ValueKey(tip), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.35, color: BC.ink)),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PrimaryButton(label: l.viewQuotes, icon: Icons.request_quote_rounded, onPressed: bids.isEmpty ? null : _openJob),
            const SizedBox(height: 8),
            SecondaryButton(label: l.cxBackHome, icon: Icons.home_rounded, onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst)),
          ]),
        ),
      ),
    );
  }
}

/// One quote that has arrived: initials, name, rating, price, and the "Best match" tag when the server marked it.
class _QuoteTile extends StatelessWidget {
  const _QuoteTile({required this.bid, required this.onTap});
  final Json bid;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final w = (bid['worker'] as Map).cast<String, dynamic>();
    final best = bid['best_match'] == true;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      borderColor: best ? BC.money : BC.line,
      child: Row(children: [
        CircleAvatar(radius: 22, backgroundColor: BC.brand, child: Text(initials('${w['name'] ?? ''}'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${w['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            StarBadge((w['rating'] as num?) ?? 0),
            if (best) ...[
              const SizedBox(height: 4),
              StatusPill(key: const ValueKey('bestMatch'), label: l.cxBestMatch, color: BC.money, bg: BC.moneySoft, icon: Icons.workspace_premium_rounded),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        MoneyText(bid['price_inr'] as num, size: MoneySize.m, alignment: AlignmentDirectional.centerEnd),
      ]),
    );
  }
}
