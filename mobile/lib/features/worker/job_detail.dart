import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/app_state.dart';
import '../../core/outbox.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/fair_price.dart';
import '../../widgets/maps.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';
import '../../widgets/team_widgets.dart';
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
  Json? _job;
  bool _failed = false;
  bool _sending = false;
  bool _prefilled = false; // pre-fill once (old quote or fair median), never again (or the field can't be cleared)
  bool _spoken = false; // auto-read the job summary once per open

  static const _step = 50;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    AudioHub.instance.stopAll();
    _price.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await widget.state.api.workerJob(widget.jobId);
      if (!mounted) return;
      final myBid = j['my_bid'] as Json?;
      if (!_prefilled && _price.text.isEmpty) {
        _prefilled = true;
        if (myBid != null) {
          _price.text = '${(myBid['price_inr'] as num).round()}';
        } else if (j['kind'] != 'team' && j['fair_range'] is Map && (j['fair_range'] as Map)['median'] is num) {
          // Start from the fair median (rounded to ₹50) so the worker only nudges it up or down.
          final m = ((j['fair_range'] as Map)['median'] as num).toDouble();
          _price.text = '${(m / _step).round() * _step}';
        }
      }
      setState(() {
        _job = j;
        _failed = false;
      });
      _autoRead(j);
    } catch (_) {
      if (mounted && _job == null) setState(() => _failed = true);
    }
  }

  String _speech(L l, Json job) {
    final items = (job['work_items'] as List).cast<Json>();
    final where = '${job['address']}${job['distance_km'] != null ? ' · ${l.kmAway((job['distance_km'] as num).toStringAsFixed(1))}' : ''}';
    final fair = job['fair_range'] is Map ? (job['fair_range'] as Map) : null;
    return [
      where,
      for (final it in items) '${l.workN(it['index'] as int)}. ${tradeLabel(l, it['trade'] as String)}. ${it['text'] ?? ''}',
      if (fair != null && fair['low'] is num && fair['high'] is num) '${l.fairRangeTitle}: ${inrRange(fair['low'] as num, fair['high'] as num)}',
    ].join('. ');
  }

  void _autoRead(Json job) {
    if (_spoken) return;
    _spoken = true;
    ReadAloud.auto(_speech(L.of(context), job), widget.state.language ?? 'hi');
  }

  int? get _amount => int.tryParse(_price.text.replaceAll(RegExp(r'[^0-9]'), ''));

  void _nudge(int delta) {
    tapFeedback();
    final cur = _amount ?? 0;
    final next = (cur + delta).clamp(100, 9999999);
    setState(() => _price.text = '$next');
  }

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
    final job = _job;
    final canQuote = job != null && _canQuote(job);
    return Scaffold(
      appBar: AppBar(title: Text(l.jobDetails, maxLines: 1, overflow: TextOverflow.ellipsis)),
      // The one primary action lives at the bottom, in the thumb zone.
      bottomNavigationBar: canQuote
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BC.line))),
                child: PrimaryButton(
                  big: true,
                  busy: _sending,
                  onPressed: (_amount ?? 0) >= 100 ? _send : null,
                  icon: Icons.send_rounded,
                  label: _amount != null && _amount! >= 100 ? l.sendPrice(inr(_amount)) : l.quotePrice,
                ),
              ),
            )
          : null,
      body: job == null
          ? (_failed
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.wifi_off_rounded, size: 56, color: BC.inkFaint),
                    const SizedBox(height: 12),
                    Text(l.errorNetwork, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    SecondaryButton(
                        label: l.retry,
                        icon: Icons.refresh_rounded,
                        expand: false,
                        onPressed: () {
                          setState(() => _failed = false);
                          _load();
                        }),
                  ]),
                )
              : const Center(child: CircularProgressIndicator(color: BC.brand)))
          : RefreshIndicator(color: BC.brand, onRefresh: _load, child: _body(context, l, lang, job)),
    );
  }

  bool _canQuote(Json job) {
    final myBid = job['my_bid'] as Json?;
    final isTeam = job['kind'] == 'team';
    final open = job['status'] == 'open' || job['status'] == 'bidding' || (isTeam && job['open_for_team'] == true);
    return open && !(myBid != null && myBid['status'] != 'pending');
  }

  Widget _stepBtn(String label, int delta, {required bool enabled}) => SizedBox(
        height: BC.tap,
        child: OutlinedButton(
          onPressed: enabled ? () => _nudge(delta) : null,
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, BC.tap), padding: const EdgeInsets.symmetric(horizontal: 8), side: const BorderSide(color: BC.brand, width: 1.5)),
          child: BtnLabel(label),
        ),
      );

  Widget _body(BuildContext context, L l, String lang, Json job) {
    final items = (job['work_items'] as List).cast<Json>();
    final myBid = job['my_bid'] as Json?;
    final isTeam = job['kind'] == 'team';
    final open = job['status'] == 'open' || job['status'] == 'bidding' || (isTeam && job['open_for_team'] == true);
    final myItem = job['my_item'] as Json?;
    final where = '${job['address']}${job['distance_km'] != null ? ' · ${l.kmAway((job['distance_km'] as num).toStringAsFixed(1))}' : ''}';
    final direct = (job['direct'] as Map?)?.cast<String, dynamic>();
    final stacked = bigText(context, 1.2);
    final field = MediaQuery.withClampedTextScaling(maxScaleFactor: 1.2, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: BC.bg, borderRadius: BorderRadius.circular(BC.r), border: Border.all(color: BC.brand, width: 1.5)),
      child: Row(children: [
        Text('₹', style: context.tt.headlineSmall!.copyWith(color: BC.inkSoft)),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: _price,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
            style: context.tt.displayLarge!.copyWith(fontSize: 28, fontFeatures: BC.tabular), // fits ₹99,999 between the ±50 buttons on a 320dp phone
            decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                filled: false, hintText: '0', hintStyle: TextStyle(color: BC.line)),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ]),
    ));
    final minus = _stepBtn('−₹$_step', -_step, enabled: (_amount ?? 0) > 100);
    final plus = _stepBtn('+₹$_step', _step, enabled: true);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      if (direct != null && open) ...[
        InfoBanner(
          icon: Icons.favorite_rounded,
          color: BC.brandDark,
          text: l.directWantsYou(widget.state.user?.name?.split(' ').first ?? '', '${direct['customer_name'] ?? ''}'),
        ),
        const SizedBox(height: 12),
      ],
      AppCard(
        padding: const EdgeInsets.fromLTRB(BC.pad, 12, 8, BC.pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.place_rounded, color: BC.brand, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(where, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium)),
            ReadButton(text: _speech(l, job), lang: lang),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(spacing: 16, runSpacing: 4, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.event_rounded, color: BC.inkFaint, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(scheduleText(l, job['scheduled_for'] as String?, job['time_slot'] as String?) ?? l.startsOn(job['start_date'] as String),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle),
                ),
              ]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.gavel_rounded, color: BC.inkFaint, size: 18),
                const SizedBox(width: 6),
                Flexible(child: Text(l.quotesSoFar(job['bid_count'] as int), maxLines: 2, overflow: TextOverflow.ellipsis, style: BC.subtle)),
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
      if (isTeam) ...[
        TeamNeedsBanner(team: job['team'] as Map?, trades: [if (myItem != null) myItem['trade'] as String], max: 6),
        const SizedBox(height: 16),
      ],
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
            // Team job: one tap accepts the contractor's daily wage; or quote your own daily rate below.
            if (isTeam && myItem != null && myBid == null) ...[
              PrimaryButton(
                big: true,
                busy: _sending,
                icon: Icons.group_add_rounded,
                label: l.teamJoinAt(inr(myItem['daily_wage_inr'] as num)),
                onPressed: () {
                  _price.text = '${(myItem['daily_wage_inr'] as num).round()}';
                  _send();
                },
              ),
              const SizedBox(height: 4),
              Text(l.teamJoinSub(myItem['days'] as int, inr((myItem['daily_wage_inr'] as num) * (myItem['days'] as int))), style: BC.subtle),
              const Divider(height: 28),
            ],
            Row(children: [
              const Icon(Icons.currency_rupee_rounded, color: BC.brand),
              const SizedBox(width: 6),
              Expanded(child: Text(isTeam ? l.teamYourDaily : (myBid == null ? l.yourPrice : l.updateYourPrice), style: context.tt.titleLarge)),
            ]),
            const SizedBox(height: 12),
            if (stacked) ...[
              field,
              const SizedBox(height: 8),
              Row(children: [Expanded(child: minus), const SizedBox(width: 8), Expanded(child: plus)]),
            ] else
              Row(children: [Expanded(flex: 3, child: minus), const SizedBox(width: 8), Expanded(flex: 5, child: field), const SizedBox(width: 8), Expanded(flex: 3, child: plus)]),
            const SizedBox(height: 10),
            VoiceAmountButton(lang: lang, onAmount: (n) => setState(() => _price.text = '$n')),
            const SizedBox(height: 12),
            if (job['fair_range'] is Map) ...[
              FairPriceBanner(fairRange: (job['fair_range'] as Map).cast<String, dynamic>(), priceInr: _amount),
              const SizedBox(height: 4),
            ],
            if (myBid != null) ...[
              const SizedBox(height: 6),
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
  }
}

/// One work card: number + trade, gallery, translated text, audio player.
class WorkItemView extends StatefulWidget {
  const WorkItemView({super.key, required this.item, required this.lang});
  final Json item;
  final String lang;
  @override
  State<WorkItemView> createState() => _WorkItemViewState();
}

class _WorkItemViewState extends State<WorkItemView> {
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
                maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium!.copyWith(color: s.color)),
          ),
          ReadButton(text: '${tradeLabel(l, it['trade'] as String)}. ${it['text'] ?? ''}', lang: widget.lang, size: 36),
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
        ],
      ]),
    );
  }
}
