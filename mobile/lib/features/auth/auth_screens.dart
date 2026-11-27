import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_state.dart';
import '../../core/demo_accounts.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';

const _bigDigits = TextStyle(fontSize: 28, fontWeight: FontWeight.w600, height: 1.3, fontFeatures: BC.tabular);

/// S2a — phone number. Huge numerals, +91 fixed, number grouped "98765 43210" for readability.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key, required this.state});
  final AppState state;
  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _digits => _c.text.replaceAll(' ', '');
  bool get _valid => RegExp(r'^[6-9]\d{9}$').hasMatch(_digits);

  Future<void> _send() async {
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.state.api.requestOtp(_digits, widget.state.language ?? 'hi');
      widget.state.pendingPhone = _digits;
      if (mounted) context.push('/otp');
    } catch (e) {
      if (mounted) setState(() => _err = errorText(L.of(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const IconBadge(Icons.phone_android_rounded, color: BC.brand, size: 52),
                const SizedBox(height: 16),
                Text(l.phoneTitle, style: context.tt.headlineMedium),
                const SizedBox(height: 4),
                Text(l.phoneSub, style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
                const SizedBox(height: 28),
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.15, // the digits are already huge
                  child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(BC.rMd),
                    border: Border.all(color: _err != null ? BC.danger : (_valid ? BC.money : BC.line), width: 1.5),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(children: [
                    Text('+91', style: _bigDigits.copyWith(color: BC.inkSoft)),
                    Container(width: 1.5, height: 32, color: BC.line, margin: const EdgeInsets.symmetric(horizontal: 12)),
                    Expanded(
                      child: TextField(
                        controller: _c,
                        autofocus: true,
                        keyboardType: TextInputType.phone,
                        autofillHints: const [AutofillHints.telephoneNumberNational],
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10), _GroupFormatter()],
                        style: _bigDigits,
                        decoration: const InputDecoration(
                            border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                            filled: false, hintText: '98765 43210', hintStyle: TextStyle(color: BC.line)),
                        onChanged: (_) => setState(() => _err = null),
                        onSubmitted: (_) => _valid && !_busy ? _send() : null,
                      ),
                    ),
                    if (_valid) const Icon(Icons.check_circle_rounded, color: BC.money, size: 28),
                  ]),
                ),
                ),
                if (_err != null) ...[
                  const SizedBox(height: 8),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline_rounded, color: BC.danger, size: 22),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_err!, style: context.tt.bodyLarge!.copyWith(color: BC.danger))),
                  ]),
                ],
                const SizedBox(height: 16),
                if (widget.state.isDemo) ...[
                  const DemoChip(),
                  const SizedBox(height: 14),
                  Text(l.demoAccounts, style: context.tt.labelLarge!.copyWith(color: BC.inkSoft)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final (phone, trade, name, role) in demoAccounts)
                      ActionChip(
                        avatar: Icon(role == 'contractor' ? Icons.engineering_rounded : (role == 'customer' ? Icons.home_work_rounded : TradeStyle.of(trade).icon),
                            color: isDemoCustomerRole(role) ? BC.info : TradeStyle.of(trade).color, size: 18),
                        label: Text('${name.split(' ').first} · ${role == 'contractor' ? l.roleContractor : (role == 'customer' ? l.role_customer : tradeLabel(l, trade))}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onPressed: () => setState(() => _c.text = '${phone.substring(0, 5)} ${phone.substring(5)}'),
                      ),
                  ]),
                ],
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: PrimaryButton(big: true, label: l.getOtp, busy: _busy, onPressed: _valid ? _send : null),
          ),
        ]),
      ),
    );
  }
}

class _GroupFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue o, TextEditingValue n) {
    final d = n.text.replaceAll(' ', '');
    final t = d.length > 5 ? '${d.substring(0, 5)} ${d.substring(5)}' : d;
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}

/// S2b — OTP. One hidden field drives six big boxes (supports SMS autofill), auto-submits on
/// the 6th digit, and has a visible resend countdown.
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.state});
  final AppState state;
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  int _left = 30;
  bool _busy = false;
  bool _error = false;
  String? _errText;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _left = 30;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_left <= 1) t.cancel();
      if (mounted) setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final s = widget.state;
    if (s.pendingPhone == null) {
      // App was restarted on this screen: the phone number is gone → go back and re-enter it.
      if (context.canPop()) context.pop();
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _error = false;
      _errText = null;
    });
    try {
      final r = await s.api.verifyOtp(s.pendingPhone!, _c.text, role: s.roleIntent, lang: s.language ?? 'hi');
      await s.signIn(r); // router redirect takes the user to their home by role
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _error = true;
        _errText = errorText(L.of(context), e);
      });
      _c.clear();
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final phone = widget.state.pendingPhone ?? '';
    final pretty = phone.length == 10 ? '${phone.substring(0, 5)} ${phone.substring(5)}' : phone;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const IconBadge(Icons.sms_rounded, color: BC.brand, size: 52),
                const SizedBox(height: 16),
                Text(l.otpTitle, style: context.tt.headlineMedium),
                const SizedBox(height: 4),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(l.otpSentTo(pretty), style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft)),
                  TextButton(onPressed: () => context.pop(), child: Text(l.changeNumber)),
                ]),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () => _focus.requestFocus(),
                  child: Stack(children: [
                    // Invisible input that owns the keyboard + SMS autofill.
                    Opacity(
                      opacity: 0,
                      child: TextField(
                        controller: _c,
                        focusNode: _focus,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        onChanged: (v) {
                          setState(() => _error = false);
                          if (v.length == 6 && !_busy) _verify();
                        },
                      ),
                    ),
                    // Six flexible boxes: they shrink on narrow phones instead of overflowing.
                    MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.15,
                      child: Row(children: [
                        for (var i = 0; i < 6; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(child: _box(i)),
                        ],
                      ]),
                    ),
                  ]),
                ),
                if (_errText != null) ...[
                  const SizedBox(height: 10),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline_rounded, color: BC.danger, size: 22),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_errText!, style: context.tt.bodyLarge!.copyWith(color: BC.danger))),
                  ]),
                ],
                const SizedBox(height: 12),
                SecondaryButton(
                  icon: Icons.content_paste_rounded,
                  label: l.wkPasteCode,
                  onPressed: () async {
                    final d = await Clipboard.getData(Clipboard.kTextPlain);
                    final m = RegExp(r'\d{6}').firstMatch(d?.text ?? '') ?? RegExp(r'\d{4,6}').firstMatch(d?.text ?? '');
                    if (m == null || !mounted) return;
                    _c.text = m.group(0)!;
                    setState(() => _error = false);
                    if (_c.text.length == 6 && !_busy) _verify();
                  },
                ),
                const SizedBox(height: 12),
                Center(
                  child: _left > 0
                      ? Text(l.otpResendIn(_left), style: context.tt.bodyLarge!.copyWith(color: BC.inkSoft, fontFeatures: BC.tabular))
                      : TextButton.icon(
                          onPressed: () async {
                            setState(_startTimer);
                            try {
                              await widget.state.api.requestOtp(phone, widget.state.language ?? 'hi');
                            } catch (e) {
                              if (mounted) showError(context, e);
                            }
                          },
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(l.otpResend),
                        ),
                ),
                if (widget.state.isDemo) ...[const SizedBox(height: 12), const Center(child: DemoChip())],
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: PrimaryButton(big: true, label: l.verify, busy: _busy, onPressed: _c.text.length == 6 ? _verify : null),
          ),
        ]),
      ),
    );
  }

  Widget _box(int i) {
    final ch = i < _c.text.length ? _c.text[i] : '';
    final active = i == _c.text.length && _focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _error ? BC.danger : active ? BC.brand : (ch.isEmpty ? BC.line : BC.ink),
          width: active || _error ? 2 : 1.2,
        ),
      ),
      child: Text(ch, style: _bigDigits),
    );
  }
}
