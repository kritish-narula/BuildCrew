import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/config.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import 'customer_home.dart' show customerRoute;
import '../../widgets/media.dart';

/// C6 payment page. The customer pays quote + ₹30 into ESCROW: BuildCrew holds it and
/// releases it to the worker only after the work is done and rated.
///
/// Security: the app never sees or stores card numbers. With live Razorpay keys this screen
/// hands off to Razorpay's own Checkout (their PCI-certified page) and the server accepts the
/// result only after verifying its signature. Without keys (demo / test mode) the payment is
/// simulated and clearly labelled as such.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.state, required this.jobId, required this.workerName, required this.price, required this.fee});
  final AppState state;
  final String jobId, workerName;
  final num price, fee;
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  String _method = 'upi';
  bool _paying = false;
  bool _verifying = false;
  Razorpay? _rzp;

  @override
  void dispose() {
    _rzp?.clear(); // removes every listener
    super.dispose();
  }

  Future<void> _pay() async {
    setState(() => _paying = true);
    try {
      final p = await widget.state.api.payJob(widget.jobId, _method);
      if (!mounted) return;
      if (p['provider'] == 'razorpay' && p['order_id'] != null && p['escrow_state'] == null) {
        _teamTotal ??= (p['remaining'] as num?)?.toInt() ?? 1;
        _openCheckout(p); // live keys: Razorpay's own PCI-certified page; result arrives via the listeners below
        return;
      }
      await _done(p);
    } catch (e) {
      if (mounted) {
        setState(() => _paying = false);
        showError(context, e);
      }
    }
  }

  Future<void> _done(Json p) async {
    HapticFeedback.heavyImpact();
    if (!mounted) return;
    setState(() => _paying = false);
    await Navigator.of(context).pushReplacement(customerRoute<void>(
      builder: (_) => PaymentSuccessScreen(payment: p, workerName: widget.workerName),
    ));
  }

  String _contact() {
    final n = (widget.state.user?.phone ?? '').replaceAll(RegExp(r'\D'), '');
    return n.length == 10 ? '+91$n' : (n.isEmpty ? '' : '+$n');
  }

  void _openCheckout(Json co) {
    final rzp = _rzp ??= (Razorpay()
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, _onSuccess)
      ..on(Razorpay.EVENT_PAYMENT_ERROR, _onError)
      ..on(Razorpay.EVENT_EXTERNAL_WALLET, _onWallet));
    _order = co;
    final upi = _method == 'upi';
    try {
      rzp.open({
        'key': co['key_id'], // PUBLIC key id; the secret never leaves the server
        'order_id': co['order_id'],
        'amount': co['amount'],
        'currency': co['currency'] ?? 'INR',
        'name': 'BuildCrew',
        'description': co['description'] ?? 'Work payment',
        'prefill': {'contact': _contact()},
        'theme': {'color': '#EA580C'},
        'timeout': 600,
        'retry': {'enabled': true, 'max_count': 2},
        // UPI first (most workers/customers pay by UPI); cards and netbanking stay available under "Other".
        if (upi)
          'config': {
            'display': {
              'blocks': {
                'upi': {'name': 'UPI', 'instruments': [{'method': 'upi'}]}
              },
              'sequence': ['block.upi'],
              'preferences': {'show_default_blocks': true},
            }
          },
      });
    } catch (e) {
      if (mounted) {
        setState(() => _paying = false);
        showError(context, e);
      }
    }
  }

  Json? _order;
  int? _teamTotal; // team jobs pay one Razorpay order per hired worker

  Future<void> _onSuccess(PaymentSuccessResponse r) async {
    if (!mounted) return;
    setState(() => _verifying = true);
    try {
      // The server checks HMAC-SHA256(order_id|payment_id) with its secret before holding the money.
      final p = await widget.state.api.payJobVerify(widget.jobId,
          orderId: r.orderId ?? '${_order?['order_id']}', paymentId: r.paymentId ?? '', signature: r.signature ?? '', method: _method);
      if (!mounted) return;
      setState(() => _verifying = false);
      final remaining = (p['remaining'] as num?)?.toInt() ?? 0;
      if (p['provider'] == 'razorpay' && p['order_id'] != null && p['escrow_state'] == null && remaining > 0) {
        // Team job: one Razorpay order per hired worker. Open the next one.
        final total = _teamTotal ?? remaining + 1;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).payTeamNext(total - remaining, total))));
        _openCheckout(p);
        return;
      }
      await _done(p);
    } catch (e) {
      if (mounted) {
        setState(() {
          _verifying = false;
          _paying = false;
        });
        showError(context, e);
      }
    }
  }

  void _onError(PaymentFailureResponse r) {
    if (!mounted) return;
    setState(() => _paying = false);
    final l = L.of(context);
    final cancelled = r.code == Razorpay.PAYMENT_CANCELLED;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(cancelled ? l.payCancelled : l.payFailed), backgroundColor: BC.ink));
  }

  void _onWallet(ExternalWalletResponse r) {
    // The user left for a wallet app (Paytm, ...). The payment.captured webhook confirms it server-side;
    // when they come back, paying again returns the already-held payment instead of charging twice.
    if (mounted) setState(() => _paying = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final total = widget.price + widget.fee;
    Widget method(String id, IconData icon, String title, String sub) {
      final on = _method == id;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: on ? BC.brandSoft : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r), side: BorderSide(color: on ? BC.brand : BC.line, width: on ? 2 : 1.2)),
          child: InkWell(
            borderRadius: BorderRadius.circular(BC.r),
            onTap: () => setState(() => _method = id),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(icon, size: 30, color: on ? BC.brandDark : BC.inkSoft),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    Text(sub, style: const TextStyle(color: BC.inkSoft)),
                  ]),
                ),
                Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: on ? BC.brand : BC.inkFaint),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.payment)),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        if (widget.state.isDemo) ...[
          InfoBanner(icon: Icons.science_rounded, color: BC.info, text: l.testModePayment),
          const SizedBox(height: 16),
        ],
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(28)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.payingFor(widget.workerName), style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(inr(total), style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
            const SizedBox(height: 12),
            _row(l.workerPrice, inr(widget.price)),
            _row(l.platformFee, inr(widget.fee)),
          ]),
        ),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.verified_user_rounded, color: BC.money, text: l.escrowExplain),
        const SizedBox(height: 12),
        const RefundPolicyBox(),
        const SizedBox(height: 20),
        Text(l.choosePaymentMethod, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        method('upi', Icons.qr_code_2_rounded, l.payUpi, l.payUpiSub),
        method('card', Icons.credit_card_rounded, l.payCard, l.paySecurePage),
        method('netbanking', Icons.account_balance_rounded, l.payNetbanking, l.paySecurePage),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.lock_rounded, size: 16, color: BC.inkSoft),
          const SizedBox(width: 6),
          Expanded(child: Text(l.paymentSecurityNote, style: const TextStyle(color: BC.inkSoft, fontSize: 13))),
        ]),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton(
            onPressed: _paying ? null : _pay,
            style: FilledButton.styleFrom(backgroundColor: BC.money),
            child: _paying
                ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)),
                    const SizedBox(width: 12),
                    Text(_verifying ? l.payVerifying : l.processingPayment),
                  ])
                : Text(l.payAmount(inr(total))),
          ),
        ),
      ),
    );
  }

  Widget _row(String a, String b) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          Text(a, style: const TextStyle(color: Colors.white70, fontSize: 15)),
          const Spacer(),
          Text(b, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
        ]),
      );
}

class PaymentSuccessScreen extends StatelessWidget {
  const PaymentSuccessScreen({super.key, required this.payment, required this.workerName});
  final Json payment;
  final String workerName;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.4, end: 1),
              duration: const Duration(milliseconds: 500),
              curve: Curves.elasticOut,
              builder: (_, v, child) => Transform.scale(scale: v, child: child),
              child: Container(
                width: 120,
                height: 120,
                decoration: const BoxDecoration(color: BC.money, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 80),
              ),
            ),
            const SizedBox(height: 24),
            Text(l.paymentSuccessful, style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(l.heldSafelyFor(inr(payment['amount_inr'] as num), workerName), textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, color: BC.inkSoft)),
            const SizedBox(height: 20),
            Text('${l.transactionId}: ${payment['ref']}', style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
            const Spacer(),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.trackWorker(workerName))),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).push(customerRoute<void>(builder: (_) => ReceiptScreen(payment: payment, workerName: workerName))),
              child: Text(l.viewReceipt, style: const TextStyle(fontSize: 16)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Receipt: what was paid, how, when, and where the money is now.
class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({super.key, required this.payment, required this.workerName, this.trades = const [], this.warrantyDays = 0});
  final Json payment;
  final String workerName;
  final List<String> trades;

  /// "30-day re-fix guarantee" line (0 = none for this trade, e.g. helper work).
  final int warrantyDays;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final state = payment['escrow_state'] as String;
    String date(String? iso) {
      if (iso == null) return '—';
      final d = DateTime.parse(iso).toLocal();
      return '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }

    final method = switch (payment['method']) { 'card' => l.payCard, 'netbanking' => l.payNetbanking, 'upi' => l.payUpi, _ => '—' };
    final rows = [
      (l.workerLabel, workerName),
      if (trades.isNotEmpty) (l.workLabel, trades.map((t) => tradeLabel(l, t)).toSet().join(', ')),
      (l.workerPrice, inr(payment['worker_payout_inr'] as num)),
      (l.platformFee, inr(payment['platform_fee_inr'] as num)),
      (l.totalPaid, inr(payment['amount_inr'] as num)),
      if ((payment['refund_inr'] as num? ?? 0) > 0) (l.refunded, inr(payment['refund_inr'] as num)),
      (l.paymentMethod, method),
      (l.paidOn, date(payment['paid_at'] as String?)),
      (l.releasedOn, date(payment['released_at'] as String?)),
      (l.transactionId, '${payment['ref']}'),
      if (warrantyDays > 0) (l.warrantyTitle, l.warrantyChip(warrantyDays)),
    ];
    final statusText = switch (state) {
      'released' => l.receiptReleased(workerName),
      'held' => l.receiptHeld,
      'refunded' => l.escrowRefunded,
      'split' => l.escrowSplit,
      _ => l.escrowCreated,
    };
    return Scaffold(
      appBar: AppBar(title: Text(l.receipt)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: BC.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: BC.brand, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.construction_rounded, color: Colors.white),
              ),
              const SizedBox(width: 10),
              const Flexible(child: Text('BuildCrew', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18))),
              const SizedBox(width: 8),
              const Spacer(),
              StatusPill(
                label: statusText,
                color: state == 'released' ? BC.money : (state == 'held' ? const Color(0xFF92400E) : BC.closed),
                bg: state == 'released' ? BC.moneySoft : (state == 'held' ? BC.pendingSoft : BC.closedSoft),
              ),
            ]),
            const SizedBox(height: 18),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                child: Text(inr(payment['amount_inr'] as num), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700, fontFeatures: BC.tabular))),
            const Divider(height: 28),
            for (final (a, b) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text(a, style: const TextStyle(color: BC.inkSoft))),
                  const SizedBox(width: 12),
                  Expanded(child: Text(b, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular))),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        const RefundPolicyBox(),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Share.share([for (final (a, b) in rows) '$a: $b'].join('\n')),
          icon: const Icon(Icons.share_rounded),
          label: BtnLabel(l.shareReceipt),
        ),
      ]),
    );
  }
}


/// #16 Cancellation and refund policy, shown on the payment page and the receipt. Short, plain, with the support line.
class RefundPolicyBox extends StatelessWidget {
  const RefundPolicyBox({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    Widget bullet(String t) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 6, color: BC.inkSoft)),
            const SizedBox(width: 8),
            Expanded(child: Text(t, style: const TextStyle(fontSize: 14, height: 1.35, color: BC.inkSoft))),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.policy_outlined, size: 20, color: BC.ink),
          const SizedBox(width: 8),
          Expanded(child: Text(l.refundPolicyTitle, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
        ]),
        bullet(l.refundPolicyBefore),
        bullet(l.refundPolicyAfter),
        bullet(l.refundPolicyNoShow),
        bullet(l.refundPolicyWarranty),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => launchUrl(Uri.parse('tel:$supportPhone')),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              const Icon(Icons.call_rounded, size: 18, color: BC.brandDark),
              const SizedBox(width: 8),
              Expanded(child: Text(l.refundPolicyHelp(supportPhoneDisplay), style: const TextStyle(fontWeight: FontWeight.w700, color: BC.brandDark))),
            ]),
          ),
        ),
      ]),
    );
  }
}
