import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/app_state.dart';
import '../../core/outbox.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/maps.dart';
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
  bool _prefilled = false; // pre-fill the old quote once, never again (or the field can't be cleared)

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
    if (_sending || amt == null || amt < 100) return;
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
          content: Text(sent ? l.bidSentSub : l.bidSavedOfflineSub, textAlign: TextAlign.center),
          actions: [PrimaryButton(onPressed: () => Navigator.pop(c), label: l.ok)],
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
      appBar: AppBar(title: Text(l.jobDetails, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: AsyncList<Json>(
        load: () => widget.state.api.workerJob(widget.jobId),
        builder: (ctx, job, reload) {
          final items = (job['work_items'] as List).cast<Json>();
          final myBid = job['my_bid'] as Json?;
          final open = job['status'] == 'open' || job['status'] == 'bidding';
          if (myBid != null && !_prefilled && _price.text.isEmpty) {
            _prefilled = true;
            _price.text = '${(myBid['price_inr'] as num).round()}';
          }
          final speech = [
            for (final it in items) '${l.workN(it['index'] as int)}. ${tradeLabel(l, it['trade'] as String)}. ${it['text'] ?? ''}'
          ].join(' ');
          final where = '${job['address']}${job['distance_km'] != null ? ' · ${l.kmAway((job['distance_km'] as num).toStringAsFixed(1))}' : ''}';
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            AppCard(
              padding: const EdgeInsets.fromLTRB(BC.pad, 12, 8, BC.pad),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.place_rounded, color: BC.brand, size: 22),
                  const SizedBox(width: 8),
                  Expanded(child: Text(where, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium)),
                  SpeakButton(text: speech, lang: lang),
                ]),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Wrap(spacing: 16, runSpacing: 4, children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.event_rounded, color: BC.inkFaint, size: 18),
                      const SizedBox(width: 6),
                      Flexible(child: Text(l.startsOn(job['start_date'] as String), maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.subtle)),
                    ]),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.gavel_rounded, color: BC.inkFaint, size: 18),
                      const SizedBox(width: 6),
                      Flexible(child: Text(l.quotesSoFar(job['bid_count'] as int), maxLines: 1, overflow: TextOverflow.ellipsis, style: BC.subtle)),
                    ]),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            // Area only (soft circle) until hired; exact pin + directions once the job is yours.
            JobMap(
              lat: (job['lat'] as num).toDouble(),
              lng: (job['lng'] as num).toDouble(),
              exact: myBid?['status'] == 'accepted',
              me: LocationService.last == null ? null : (LocationService.last!.latitude, LocationService.last!.longitude),
              height: 160,
              onDirections: myBid?['status'] == 'accepted'
                  ? () => LocationService.directions((job['lat'] as num).toDouble(), (job['lng'] as num).toDouble())
                  : null,
            ),
            const SizedBox(height: 16),
            for (final it in items) ...[
              WorkItemView(item: it, lang: lang),
              const SizedBox(height: 16),
            ],
            if (myBid != null && myBid['status'] != 'pending')
              Align(
                alignment: Alignment.centerLeft,
                child: StatusPill(
                    label: myBid['status'] == 'accepted' ? l.bidAccepted : l.bidNotSelected,
                    color: myBid['status'] == 'accepted' ? BC.money : BC.closed,
                    bg: myBid['status'] == 'accepted' ? BC.moneySoft : BC.closedSoft),
              )
            else if (open)
              AppCard(
                padding: const EdgeInsets.all(BC.padLg),
                shadow: true,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(myBid == null ? l.yourPrice : l.updateYourPrice, style: context.tt.titleLarge),
                  const SizedBox(height: 2),
                  Text(l.yourPriceSub, style: BC.subtle),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    decoration: BoxDecoration(color: BC.bg, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.brand, width: 1.5)),
                    child: Row(children: [
                      Text('₹', style: context.tt.displayMedium!.copyWith(color: BC.inkSoft)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _price,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
                          style: context.tt.displayLarge!.copyWith(fontSize: 38),
                          decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                              filled: false, hintText: '0', hintStyle: TextStyle(color: BC.line)),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  VoiceAmountButton(lang: lang, onAmount: (n) => setState(() => _price.text = '$n')),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    big: true,
                    busy: _sending,
                    onPressed: (_amount ?? 0) >= 100 ? _send : null,
                    icon: Icons.send_rounded,
                    label: _amount != null && _amount! >= 100 ? l.sendPrice(inr(_amount)) : l.quotePrice,
                  ),
                  if (myBid != null) ...[
                    const SizedBox(height: 10),
                    SecondaryButton(
                      onPressed: () => openChat(context, widget.state, jobId: widget.jobId, withUser: job['customer_id'] as String? ?? '', title: l.chatWithCustomer),
                      icon: Icons.chat_bubble_outline_rounded,
                      label: l.chatWithCustomer,
                    ),
                  ],
                ]),
              )
            else
              Align(alignment: Alignment.centerLeft, child: StatusPill(label: l.jobClosedMsg, color: BC.closed, bg: BC.closedSoft)),
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
    final fromLang = it['original_language'] as String?;
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(8)),
            child: Text(l.workN(it['index'] as int), maxLines: 1, style: context.tt.labelLarge!.copyWith(color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Icon(s.icon, color: s.color, size: 22),
          const SizedBox(width: 6),
          Expanded(
            child: Text(tradeLabel(l, it['trade'] as String),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium!.copyWith(color: s.color)),
          ),
        ]),
        const SizedBox(height: 12),
        if (photos.isNotEmpty) ...[PhotoGallery(photos: photos), const SizedBox(height: 12)],
        if (it['text'] != null) ...[
          Text(it['text'] as String, style: context.tt.bodyLarge),
          if (it['translated'] == true && fromLang != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l.translatedFrom(nativeName(fromLang)), style: BC.caption.copyWith(color: BC.inkFaint)),
            ),
          const SizedBox(height: 12),
        ],
        if (audio != null) ...[
          AudioPlayerCard(
            url: audio['url'] as String,
            durationSec: (audio['duration_sec'] as num).toInt(),
            sizeKb: (audio['size_kb'] as num?)?.toInt(),
            label: it['translated'] == true && fromLang != null ? l.listenIn(nativeName(fromLang)) : l.customerVoiceNote,
          ),
          if (it['transcript'] != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _showText = !_showText),
                icon: Icon(_showText ? Icons.expand_less_rounded : Icons.notes_rounded),
                label: BtnLabel(_showText ? l.hideText : l.showText),
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _showText ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: BC.bg, borderRadius: BorderRadius.circular(BC.rSm), border: Border.all(color: BC.line)),
                child: Text(it['transcript'] as String, style: context.tt.bodyLarge),
              ),
            ),
          ],
        ],
      ]),
    );
  }
}
