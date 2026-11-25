import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_state.dart';
import '../../core/demo_accounts.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';

const _bigDigits = TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 2, fontFeatures: BC.tabular);

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

  String get _digits => _c.text.replaceAll(' ', '');
  bool get _valid => RegExp(r'^[6-9]\d{9}$').hasMatch(_digits);

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await widget.state.api.requestOtp(_digits, widget.state.language ?? 'hi');
      widget.state.pendingPhone = _digits;
      if (mounted) context.push('/otp');
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
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.phone_android_rounded, size: 44, color: BC.brand),
            const SizedBox(height: 12),
            Text(l.phoneTitle, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(l.phoneSub, style: const TextStyle(color: BC.inkSoft, fontSize: 16)),
            const SizedBox(height: 28),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(BC.rLg),
                border: Border.all(color: _valid ? BC.money : BC.line, width: 2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                const Text('🇮🇳 +91', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: BC.inkSoft)),
                Container(width: 1.5, height: 36, color: BC.line, margin: const EdgeInsets.symmetric(horizontal: 12)),
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
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _valid && !_busy ? _send() : null,
                  ),
                ),
                if (_valid) const Icon(Icons.check_circle_rounded, color: BC.money, size: 30),
              ]),
            ),
            const SizedBox(height: 16),
            if (widget.state.isDemo) ...[
              const DemoChip(),
              const SizedBox(height: 14),
              Text(L.of(context).demoAccounts, style: const TextStyle(fontWeight: FontWeight.w700, color: BC.inkSoft)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (phone, trade, name, role) in demoAccounts)
                  ActionChip(
                    avatar: Icon(role == 'customer' ? Icons.home_work_rounded : TradeStyle.of(trade).icon,
                        color: role == 'customer' ? BC.info : TradeStyle.of(trade).color, size: 20),
                    label: Text('${name.split(' ').first} · ${role == 'customer' ? L.of(context).role_customer : tradeLabel(L.of(context), trade)}'),
                    onPressed: () => setState(() => _c.text = '${phone.substring(0, 5)} ${phone.substring(5)}'),
                  ),
              ]),
            ],
            const Spacer(),
            FilledButton(
              onPressed: _valid && !_busy ? _send : null,
              child: _busy
                  ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                  : Text(l.getOtp),
            ),
          ]),
        ),
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
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      final r = await s.api.verifyOtp(s.pendingPhone!, _c.text, role: s.roleIntent, lang: s.language ?? 'hi');
      await s.signIn(r); // router redirect takes the user to their home by role
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() => _error = true);
      _c.clear();
      showError(context, e);
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.sms_rounded, size: 44, color: BC.brand),
            const SizedBox(height: 12),
            Text(l.otpTitle, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Row(children: [
              Text(l.otpSentTo(pretty), style: const TextStyle(color: BC.inkSoft, fontSize: 16)),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(6, (i) {
                    final ch = i < _c.text.length ? _c.text[i] : '';
                    final active = i == _c.text.length && _focus.hasFocus;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 50,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _error ? BC.danger : active ? BC.brand : (ch.isEmpty ? BC.line : BC.ink),
                          width: active || _error ? 2.5 : 1.5,
                        ),
                      ),
                      child: Text(ch, style: _bigDigits.copyWith(letterSpacing: 0)),
                    );
                  }),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            Center(
              child: _left > 0
                  ? Text(l.otpResendIn(_left), style: const TextStyle(color: BC.inkSoft, fontSize: 16, fontFeatures: BC.tabular))
                  : TextButton.icon(
                      onPressed: () async {
                        _startTimer();
                        try {
                          await widget.state.api.requestOtp(phone, widget.state.language ?? 'hi');
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(l.otpResend, style: const TextStyle(fontSize: 17)),
                    ),
            ),
            if (widget.state.isDemo) ...[const SizedBox(height: 12), const Center(child: DemoChip())],
            const Spacer(),
            FilledButton(
              onPressed: _c.text.length == 6 && !_busy ? _verify : null,
              child: _busy
                  ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                  : Text(l.verify),
            ),
          ]),
        ),
      ),
    );
  }
}
