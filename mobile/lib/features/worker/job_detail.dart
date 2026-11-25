import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/outbox.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';
import '../common/chat.dart';
import '../onboarding/onboarding.dart' show nativeName;

/// S5 — Work 1, Work 2… each with photos, translated text, a big audio player and a
/// "Show text" toggle. Below: price with huge numerals + voice input. One action: send price.
class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.state, required this.jobId});
  final AppState state;
  final String jobId;
  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  final _price = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    AudioHub.instance.stopAll();
    _price.dispose();
    super.dispose();
  }

  int? get _amount => int.tryParse(_price.text.replaceAll(RegExp(r'[^0-9]'), ''));

  Future<void> _send() async {
    final l = L.of(context);
    final amt = _amount;
    if (amt == null || amt < 100) return;
    setState(() => _sending = true);
    try {
      final sent = await Outbox.instance.bid(widget.jobId, amt);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: Icon(sent ? Icons.check_circle_rounded : Icons.cloud_upload_rounded, color: sent ? BC.money : BC.pending, size: 64),
          title: Text(sent ? l.bidSent(inr(amt)) : l.bidSavedOffline, textAlign: TextAlign.center),
          content: Text(sent ? l.bidSentSub : l.bidSavedOfflineSub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final lang = widget.state.language ?? 'hi';
    return Scaffold(
      appBar: AppBar(title: Text(l.jobDetails)),
      body: AsyncList<Json>(
        load: () => widget.state.api.workerJob(widget.jobId),
        builder: (ctx, job, reload) {
          final items = (job['work_items'] as List).cast<Json>();
          final myBid = job['my_bid'] as Json?;
          final open = job['status'] == 'open' || job['status'] == 'bidding';
          if (myBid != null && _price.text.isEmpty) _price.text = '${(myBid['price_inr'] as num).round()}';
          final speech = [
            for (final it in items) '${l.workN(it['index'] as int)}. ${tradeLabel(l, it['trade'] as String)}. ${it['text'] ?? ''}'
          ].join(' ');
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Row(children: [
              const Icon(Icons.place_rounded, color: BC.inkSoft),
              const SizedBox(width: 4),
              Expanded(
                child: Text('${job['address']}${job['distance_km'] != null ? ' · ${l.kmAway((job['distance_km'] as num).toStringAsFixed(1))}' : ''}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: BC.inkSoft)),
              ),
              SpeakButton(text: speech, lang: lang),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.event_rounded, color: BC.inkSoft, size: 20),
              const SizedBox(width: 6),
              Text(l.startsOn(job['start_date'] as String), style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(l.quotesSoFar(job['bid_count'] as int), style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 16),
            for (final it in items) ...[
              WorkItemView(item: it, lang: lang),
              const SizedBox(height: 16),
            ],
            if (myBid != null && myBid['status'] != 'pending')
              StatusPill(
                  label: myBid['status'] == 'accepted' ? l.bidAccepted : l.bidNotSelected,
                  color: myBid['status'] == 'accepted' ? BC.money : BC.closed,
                  bg: myBid['status'] == 'accepted' ? BC.moneySoft : BC.closedSoft)
            else if (open) ...[
              Text(myBid == null ? l.yourPrice : l.updateYourPrice, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(l.yourPriceSub, style: const TextStyle(color: BC.inkSoft)),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(BC.rLg), border: Border.all(color: BC.brand, width: 2)),
                child: Row(children: [
                  const Text('₹', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: BC.inkSoft)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _price,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
                      style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, fontFeatures: BC.tabular),
                      decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                          filled: false, hintText: '0', hintStyle: TextStyle(color: BC.line)),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              VoiceAmountButton(lang: lang, onAmount: (n) => setState(() => _price.text = '$n')),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: (_amount ?? 0) >= 100 && !_sending ? _send : null,
                icon: _sending
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                    : const Icon(Icons.send_rounded),
                label: Text(_amount != null && _amount! >= 100 ? l.sendPrice(inr(_amount)) : l.quotePrice),
              ),
              if (myBid != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => openChat(context, widget.state, jobId: widget.jobId, withUser: job['customer_id'] as String? ?? '', title: l.chatWithCustomer),
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: Text(l.chatWithCustomer),
                ),
              ],
            ] else
              StatusPill(label: l.jobClosedMsg, color: BC.closed, bg: BC.closedSoft),
          ]);
        },
      ),
    );
  }
}

/// One work card: number + trade, gallery, translated text, audio player, transcript toggle.
class WorkItemView extends StatefulWidget {
  const WorkItemView({super.key, required this.item, required this.lang});
  final Json item;
  final String lang;
  @override
  State<WorkItemView> createState() => _WorkItemViewState();
}

class _WorkItemViewState extends State<WorkItemView> {
  bool _showText = false;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final it = widget.item;
    final audio = it['audio'] as Map?;
    final photos = (it['photos'] as List).cast<String>();
    final s = TradeStyle.of(it['trade'] as String);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(8)),
              child: Text(l.workN(it['index'] as int), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            Icon(s.icon, color: s.color),
            const SizedBox(width: 4),
            Text(tradeLabel(l, it['trade'] as String), style: TextStyle(color: s.color, fontWeight: FontWeight.w800, fontSize: 17)),
          ]),
          const SizedBox(height: 12),
          if (photos.isNotEmpty) ...[PhotoGallery(photos: photos), const SizedBox(height: 12)],
          if (it['text'] != null) ...[
            Text(it['text'] as String, style: const TextStyle(fontSize: 18, height: 1.5)),
            if (it['translated'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l.translatedFrom(nativeName(it['original_language'] as String)),
                    style: const TextStyle(color: BC.inkFaint, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 12),
          ],
          if (audio != null) ...[
            AudioPlayerCard(
              url: audio['url'] as String,
              durationSec: (audio['duration_sec'] as num).toInt(),
              sizeKb: (audio['size_kb'] as num?)?.toInt(),
              label: it['translated'] == true ? l.listenIn(nativeName(it['original_language'] as String)) : l.customerVoiceNote,
            ),
            if (it['transcript'] != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _showText = !_showText),
                icon: Icon(_showText ? Icons.expand_less_rounded : Icons.notes_rounded),
                label: Text(_showText ? l.hideText : l.showText, style: const TextStyle(fontSize: 16)),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: _showText ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: BC.bg, borderRadius: BorderRadius.circular(12)),
                  child: Text(it['transcript'] as String, style: const TextStyle(fontSize: 16, height: 1.5)),
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}
