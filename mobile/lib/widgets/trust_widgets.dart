import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'common.dart';

/// Small building blocks for the trust features: police-verified shield, skill level, warranty chip,
/// the customer's 4-digit start code, the worker's code entry and the share-trip message.

String levelLabel(L l, String? code) => switch (code) {
      'semi_skilled' => l.levelSemi,
      'skilled' => l.levelSkilled,
      'master' => l.levelMaster,
      _ => l.levelHelper,
    };

Color levelColor(String? code) => switch (code) {
      'semi_skilled' => BC.info,
      'skilled' => BC.money,
      'master' => BC.brandDark,
      _ => BC.closed,
    };

/// Shield = police verified (blue tick = UPI/selfie verified is a different, older badge).
class PoliceBadge extends StatelessWidget {
  const PoliceBadge({super.key, this.label = false, this.size = 18});
  final bool label;
  final double size;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (label) return StatusPill(label: l.policeVerified, color: BC.money, bg: BC.moneySoft, icon: Icons.shield_rounded);
    return Semantics(label: l.policeVerified, child: Icon(Icons.shield_rounded, color: BC.money, size: size));
  }
}

/// "Skilled" etc. as a small pill. Helper (the entry level) is hidden unless [showHelper].
class LevelChip extends StatelessWidget {
  const LevelChip(this.code, {super.key, this.showHelper = false});
  final String? code;
  final bool showHelper;
  @override
  Widget build(BuildContext context) {
    if (code == null || (code == 'helper' && !showHelper)) return const SizedBox.shrink();
    final c = levelColor(code);
    return StatusPill(label: levelLabel(L.of(context), code), color: c, bg: c.withValues(alpha: 0.1), icon: Icons.military_tech_rounded);
  }
}

/// "30-day re-fix guarantee". Nothing for 0 days.
class WarrantyChip extends StatelessWidget {
  const WarrantyChip(this.days, {super.key});
  final int days;
  @override
  Widget build(BuildContext context) {
    if (days <= 0) return const SizedBox.shrink();
    return StatusPill(label: L.of(context).warrantyChip(days), color: BC.info, bg: BC.infoSoft, icon: Icons.build_circle_rounded);
  }
}

/// Name row decoration used on worker cards: UPI-verified tick + police shield.
class WorkerMarks extends StatelessWidget {
  const WorkerMarks(this.w, {super.key, this.size = 18});
  final Json w;
  final double size;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (w['verified'] == true) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, color: BC.info, size: size)),
        if (w['police_verified'] == true) Padding(padding: const EdgeInsets.only(left: 4), child: PoliceBadge(size: size)),
      ]);
}

// ------------------------------------------------------------------ start code (customer side)
/// Four big read-only digits. Sized so four boxes + gaps fit in 232 dp (a 320 dp phone inside two paddings).
class CodeBoxes extends StatelessWidget {
  const CodeBoxes(this.code, {super.key, this.big = true});
  final String code;
  final bool big;
  @override
  Widget build(BuildContext context) {
    final w = big ? 52.0 : 40.0, h = big ? 64.0 : 48.0;
    return Semantics(
      label: code.split('').join(' '),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 4; i++)
          Container(
            width: w,
            height: h,
            margin: EdgeInsets.only(left: i == 0 ? 0 : 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.rSm), border: Border.all(color: BC.brand, width: 2)),
            child: Text(i < code.length ? code[i] : '', style: TextStyle(fontSize: big ? 34 : 24, fontWeight: FontWeight.w800, color: BC.ink, fontFeatures: BC.tabular)),
          ),
      ]),
    );
  }
}

/// The customer's start code, shown big after paying: "Tell this code to Ramesh when he arrives".
/// [view] is `assignment.start_code` = `{code, needed, state, locked_until, attempts_left}`.
class StartCodeCard extends StatelessWidget {
  const StartCodeCard({super.key, required this.view, required this.workerName});
  final Json view;
  final String workerName;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final code = view['code'] as String?;
    if (view['needed'] != true || code == null) return const SizedBox.shrink();
    final locked = view['state'] == 'locked';
    return Container(
      padding: const EdgeInsets.all(BC.padLg),
      decoration: BoxDecoration(color: BC.brandSoft, borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: BC.brand.withValues(alpha: 0.5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconBadge(Icons.password_rounded, color: BC.brand, size: 40, solid: true),
          const SizedBox(width: 12),
          Expanded(child: Text(l.startCodeTitle, style: context.tt.titleLarge)),
        ]),
        const SizedBox(height: 8),
        Text(l.startCodeTell(workerName), style: context.tt.titleMedium),
        const SizedBox(height: 14),
        Center(child: CodeBoxes(code)),
        const SizedBox(height: 12),
        Text(l.startCodeWhy, style: BC.subtle),
        if (locked) ...[
          const SizedBox(height: 10),
          InfoBanner(icon: Icons.lock_clock_rounded, color: BC.danger, text: l.startCodeLockedCust(workerName)),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ start code (worker side)
/// Four boxes, one hidden number field on top: tapping a box opens the number pad.
class CodeEntry extends StatefulWidget {
  const CodeEntry({super.key, required this.onChanged, this.error = false, this.enabled = true});
  final ValueChanged<String> onChanged;
  final bool error, enabled;
  @override
  State<CodeEntry> createState() => _CodeEntryState();
}

class _CodeEntryState extends State<CodeEntry> {
  final _c = TextEditingController();
  final _f = FocusNode();

  @override
  void initState() {
    super.initState();
    _f.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final text = _c.text;
    return SizedBox(
      height: 68,
      child: Stack(alignment: Alignment.center, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 52,
              height: 64,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(BC.rSm),
                border: Border.all(
                    color: widget.error ? BC.danger : (_f.hasFocus && i == text.length.clamp(0, 3) ? BC.brand : BC.line), width: _f.hasFocus && i == text.length ? 2.5 : 1.5),
              ),
              child: Text(i < text.length ? text[i] : '', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: BC.ink)),
            ),
        ]),
        Positioned.fill(
          child: Semantics(
            label: l.startCodeEnterTitle,
            textField: true,
            child: TextField(
              controller: _c,
              focusNode: _f,
              autofocus: true,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              showCursor: false,
              enableInteractiveSelection: false,
              style: const TextStyle(color: Colors.transparent, fontSize: 1),
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (v) {
                setState(() {});
                widget.onChanged(v);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class StartCodeResult {
  const StartCodeResult(this.code, {this.offline = false});
  final String code;

  /// There was no network: the code is only saved and will be verified when the check-in syncs.
  final bool offline;
}

/// Worker: "Enter the 4-digit code" sheet. [submit] checks the code online (e.g. `startWork`); a wrong code is
/// shown inside the sheet so he can try again; with no network the code is kept ([StartCodeResult.offline]).
Future<StartCodeResult?> showStartCodeSheet(BuildContext context, {required Future<void> Function(String code) submit}) =>
    showModalBottomSheet<StartCodeResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _StartCodeSheet(submit: submit),
    );

class _StartCodeSheet extends StatefulWidget {
  const _StartCodeSheet({required this.submit});
  final Future<void> Function(String code) submit;
  @override
  State<_StartCodeSheet> createState() => _StartCodeSheetState();
}

class _StartCodeSheetState extends State<_StartCodeSheet> {
  String _code = '';
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(_code);
      if (mounted) Navigator.pop(context, StartCodeResult(_code));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNetwork) {
        Navigator.pop(context, StartCodeResult(_code, offline: true));
        return;
      }
      setState(() {
        _error = errorText(L.of(context), e);
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(L.of(context), e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.startCodeEnterTitle, style: context.tt.titleLarge),
            const SizedBox(height: 6),
            Text(l.startCodeEnterSub, style: BC.subtle),
            const SizedBox(height: 18),
            CodeEntry(error: _error != null, enabled: !_busy, onChanged: (v) => setState(() {
                  _code = v;
                  _error = null;
                })),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: BC.danger, fontWeight: FontWeight.w700, fontSize: 15, height: 1.4)),
            ],
            const SizedBox(height: 18),
            PrimaryButton(big: true, color: BC.money, icon: Icons.play_arrow_rounded, busy: _busy, label: l.startCodeStart, onPressed: _code.length == 4 ? _go : null),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ share live trip
String _hideTrade(L l, String code) => tradeLabel(l, code);

/// The message that goes to family / friends: name, trade, police-verified, masked phone and the live link.
/// The customer's address is never part of it. Demo and real backend produce exactly the same text.
String shareTripMessage(L l, Json trip) {
  final name = trip['worker_name'] as String? ?? '';
  final trade = _hideTrade(l, trip['trade'] as String? ?? 'helper');
  final phone = trip['worker_phone_masked'] as String? ?? '';
  final url = trip['url'] as String? ?? '';
  return trip['police_verified'] == true ? l.shareTripTextVerified(name, trade, phone, url) : l.shareTripText(name, trade, phone, url);
}

/// Customer: creates the link, previews the message and opens the system share sheet.
Future<void> showShareTripSheet(BuildContext context, Api api, String jobId) async {
  final l = L.of(context);
  Json trip;
  try {
    trip = await api.shareTrip(jobId);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.shareTripTitle, style: c.tt.titleLarge),
          const SizedBox(height: 6),
          Text(l.shareTripSub, style: BC.subtle),
          const SizedBox(height: 14),
          AppCard(
            color: BC.closedSoft,
            child: Text(shareTripMessage(l, trip), key: const ValueKey('shareTripPreview'), style: c.tt.bodyLarge),
          ),
          const SizedBox(height: 8),
          Text(l.shareTripValid, style: BC.caption),
          const SizedBox(height: 14),
          PrimaryButton(
            icon: Icons.share_rounded,
            label: l.shareTripSend,
            onPressed: () {
              Share.share(shareTripMessage(l, trip));
              Navigator.pop(c);
            },
          ),
        ]),
      ),
    ),
  );
}
