import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
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

  Future<void> _pay() async {
    setState(() => _paying = true);
    try {
      final p = await widget.state.api.payJob(widget.jobId, _method);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => PaymentSuccessScreen(payment: p, workerName: widget.workerName),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
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
                    Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
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
            Text(inr(total), style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
            const SizedBox(height: 12),
            _row(l.workerPrice, inr(widget.price)),
            _row(l.platformFee, inr(widget.fee)),
          ]),
        ),
        const SizedBox(height: 16),
        InfoBanner(icon: Icons.verified_user_rounded, color: BC.money, text: l.escrowExplain),
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
                    Text(l.processingPayment),
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
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReceiptScreen(payment: payment, workerName: workerName))),
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
  const ReceiptScreen({super.key, required this.payment, required this.workerName, this.trades = const []});
  final Json payment;
  final String workerName;
  final List<String> trades;

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
              const Text('BuildCrew', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              const Spacer(),
              StatusPill(
                label: statusText,
                color: state == 'released' ? BC.money : (state == 'held' ? const Color(0xFF92400E) : BC.closed),
                bg: state == 'released' ? BC.moneySoft : (state == 'held' ? BC.pendingSoft : BC.closedSoft),
              ),
            ]),
            const SizedBox(height: 18),
            Text(inr(payment['amount_inr'] as num), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
            const Divider(height: 28),
            for (final (a, b) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 130, child: Text(a, style: const TextStyle(color: BC.inkSoft))),
                  Expanded(child: Text(b, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular))),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Share.share([for (final (a, b) in rows) '$a: $b'].join('\n')),
          icon: const Icon(Icons.share_rounded),
          label: Text(l.shareReceipt),
        ),
      ]),
    );
  }
}
