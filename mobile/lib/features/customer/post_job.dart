import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:latlong2/latlong.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/maps.dart';
import '../../widgets/media.dart';

const trades = ['mason', 'plumber', 'electrician', 'carpenter', 'painter', 'helper'];

/// One "work card" = one trade with photos + text + voice note (both allowed, never either/or).
class WorkDraft {
  WorkDraft(this.trade);
  String trade;
  final List<String> photos = [];
  final text = TextEditingController();
  final transcript = TextEditingController();
  RecordedNote? audio;
  String? audioKey; // set once uploaded
  bool uploading = false, transcribing = false, uploadFailed = false;
  bool get hasContent => photos.isNotEmpty || text.text.trim().isNotEmpty || audio != null;
}

/// C2 — the core flow: 1 trades → 2 work cards → 3 place & date → 4 fair price → post.
class PostJobScreen extends StatefulWidget {
  const PostJobScreen({super.key, required this.state});
  final AppState state;
  @override
  State<PostJobScreen> createState() => _PostJobScreenState();
}

class _PostJobScreenState extends State<PostJobScreen> {
  int _step = 0;
  final List<WorkDraft> _works = [];
  LatLng? _point; // exact job location (map pin)
  final _area = TextEditingController(); // locality, auto-filled from the pin, editable
  String _city = '';
  final _address = TextEditingController();
  final _picker = GlobalKey<LocationPickerState>();
  bool _lookingUp = false, _askedGps = false;
  DateTime _start = DateTime.now().add(const Duration(days: 1));
  Json? _estimate;
  bool _posting = false, _locating = false;

  String get _lang => widget.state.language ?? 'hi';

  @override
  void dispose() {
    _area.dispose();
    _address.dispose();
    super.dispose();
  }

  bool get _canNext => switch (_step) {
        0 => _works.isNotEmpty,
        1 => _works.every((w) => w.hasContent) && !_works.any((w) => w.uploading),
        2 => _point != null && _area.text.trim().isNotEmpty && _address.text.trim().length >= 3,
        _ => true,
      };

  void _toggleTrade(String t) => setState(() {
        final i = _works.indexWhere((w) => w.trade == t);
        i >= 0 ? _works.removeAt(i) : _works.add(WorkDraft(t));
      });

  Future<void> _next() async {
    if (_step == 2) {
      setState(() => _step = 3);
      try {
        final e = await widget.state.api.priceEstimate(
          _works.map((w) => w.trade).toList(),
          _area.text.trim(),
          texts: _works.map<String?>((w) => w.text.text.trim()).toList(),
          city: _city.isEmpty ? null : _city,
        );
        if (mounted) setState(() => _estimate = e);
      } catch (_) {}
      return;
    }
    if (_step < 3) setState(() => _step++);
    if (_step == 2 && !_askedGps) {
      _askedGps = true;
      final p = LocationService.last ?? await LocationService.quiet();
      if (p != null && mounted && _point == null) _setPoint(LatLng(p.latitude, p.longitude), move: true);
    }
  }

  // ---------------------------------------------------------------- audio
  Future<void> _record(WorkDraft w) async {
    final l = L.of(context);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('voice_consent') != true) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.mic_rounded, color: BC.brand, size: 40),
          title: Text(l.voiceNote),
          content: Text(l.voiceConsent, style: const TextStyle(fontSize: 16)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.agree)),
          ],
        ),
      );
      if (ok != true) return;
      await prefs.setBool('voice_consent', true);
    }
    if (!mounted) return;
    final note = await showRecorderSheet(context);
    if (note == null || !mounted) return;
    setState(() {
      w.audio = note;
      w.audioKey = null;
      w.transcript.clear();
    });
    await _uploadAudio(w);
  }

  /// Upload right after attaching so the transcript is ready to review before posting.
  Future<void> _uploadAudio(WorkDraft w) async {
    final a = w.audio;
    if (a == null) return;
    setState(() {
      w.uploading = true;
      w.uploadFailed = false;
    });
    try {
      w.audioKey = (await widget.state.api.upload('audio', a.path))['key'] as String;
    } on ApiException catch (e) {
      if (e.isNetwork) {
        w.uploadFailed = true; // kept on the phone; retried when posting
      } else if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() {
          w.uploading = false;
          w.transcribing = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------- location
  Future<void> _useGps() async {
    setState(() => _locating = true);
    final p = await LocationService.get(context);
    if (!mounted) return;
    setState(() => _locating = false);
    if (p != null) _setPoint(LatLng(p.latitude, p.longitude), move: true);
  }

  /// Pin moved (GPS or drag) → look up the real address for it.
  Future<void> _setPoint(LatLng pt, {bool move = false}) async {
    setState(() => _point = pt);
    if (move) WidgetsBinding.instance.addPostFrameCallback((_) => _picker.currentState?.moveTo(pt));
    setState(() => _lookingUp = true);
    final a = await LocationService.address(pt.latitude, pt.longitude);
    if (!mounted) return;
    setState(() {
      _lookingUp = false;
      if (a != null) {
        _area.text = a.area;
        _city = a.city;
        if (a.line.isNotEmpty) _address.text = a.line;
      }
    });
  }

  // ---------------------------------------------------------------- post
  Future<void> _post() async {
    final l = L.of(context);
    setState(() => _posting = true);
    try {
      final items = <Json>[];
      for (final w in _works) {
        if (w.audio != null && w.audioKey == null) await _uploadAudio(w);
        if (w.audio != null && w.audioKey == null) throw ApiException('network', '');
        final keys = <String>[];
        for (final p in w.photos) {
          keys.add((await widget.state.api.upload('photo', p))['key'] as String);
        }
        items.add({
          'trade': w.trade,
          'text_description': w.text.text.trim().isEmpty ? null : w.text.text.trim(),
          'transcript': null,
          'description_language': _lang,
          'audio_key': w.audioKey,
          'audio_duration_sec': w.audio?.seconds,
          'audio_size_bytes': w.audio?.bytes,
          'photo_keys': keys,
        });
      }
      await widget.state.api.createJob({
        'location_lat': _point!.latitude, 'location_lng': _point!.longitude, 'address_text': _address.text.trim(),
        'city': _city.isEmpty ? _area.text.trim() : _city, 'locality': _area.text.trim(),
        'start_date': _start.toIso8601String().substring(0, 10), 'work_items': items,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: BC.money, size: 64),
          title: Text(l.jobPosted, textAlign: TextAlign.center),
          content: Text(l.jobPostedSub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final titles = [l.stepWhatWork, l.stepDescribe, l.stepWhereWhen, l.stepFairPrice];
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.postJob),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  for (var i = 0; i < 4; i++)
                    Expanded(
                      child: Container(
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(color: i <= _step ? BC.brand : BC.line, borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                ]),
                const SizedBox(height: 8),
                Text('${_step + 1}/4 · ${titles[_step]}', style: const TextStyle(fontWeight: FontWeight.w700, color: BC.inkSoft)),
              ]),
            ),
          ),
        ),
        body: switch (_step) { 0 => _tradesStep(l), 1 => _describeStep(l), 2 => _whereStep(l), _ => _priceStep(l) },
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: _step < 3
                ? FilledButton(onPressed: _canNext ? _next : null, child: Text(l.continueBtn))
                : FilledButton.icon(
                    onPressed: _posting ? null : _post,
                    icon: _posting ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)) : const Icon(Icons.send_rounded),
                    label: BtnLabel(l.postJobNow),
                  ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- step 1
  Widget _tradesStep(L l) => GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
        children: [
          for (final t in trades)
            Builder(builder: (ctx) {
              final on = _works.any((w) => w.trade == t);
              final s = TradeStyle.of(t);
              return Material(
                color: on ? s.color.withValues(alpha: 0.12) : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.rLg), side: BorderSide(color: on ? s.color : BC.line, width: on ? 2.5 : 1.2)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(BC.rLg),
                  onTap: () => _toggleTrade(t),
                  child: Stack(children: [
                    Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(s.icon, size: 48, color: s.color),
                        const SizedBox(height: 8),
                        Text(tradeLabel(l, t), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                    if (on) Positioned(top: 10, right: 10, child: Icon(Icons.check_circle_rounded, color: s.color, size: 28)),
                  ]),
                ),
              );
            }),
        ],
      );

  // ---------------------------------------------------------------- step 2
  Widget _describeStep(L l) => ListView(padding: const EdgeInsets.all(16), children: [
        for (final (i, w) in _works.indexed) ...[
          _WorkCardEditor(
            index: i,
            draft: w,
            onChanged: () => setState(() {}),
            onRecord: () => _record(w),
            onRetryUpload: () => _uploadAudio(w),
            onRemove: _works.length > 1 ? () => setState(() => _works.removeAt(i)) : null,
          ),
          const SizedBox(height: 14),
        ],
        OutlinedButton.icon(
          onPressed: () async {
            final t = await showModalBottomSheet<String>(
              context: context,
              builder: (c) => SafeArea(
                child: Wrap(children: [
                  for (final t in trades)
                    ListTile(minTileHeight: 60, leading: Icon(TradeStyle.of(t).icon, color: TradeStyle.of(t).color), title: Text(tradeLabel(l, t), style: const TextStyle(fontSize: 17)),
                        onTap: () => Navigator.pop(c, t)),
                ]),
              ),
            );
            if (t != null) setState(() => _works.add(WorkDraft(t)));
          },
          icon: const Icon(Icons.add_rounded),
          label: BtnLabel(l.addWorkItem),
        ),
      ]);

  // ---------------------------------------------------------------- step 3
  Widget _whereStep(L l) => ListView(padding: const EdgeInsets.all(16), children: [
        LocationPicker(
          key: _picker,
          initial: _point ?? (LocationService.last != null ? LatLng(LocationService.last!.latitude, LocationService.last!.longitude) : const LatLng(20.59, 78.96)),
          initialZoom: _point != null || LocationService.last != null ? 16 : 4.5,
          onChanged: (p) => _setPoint(p),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.pan_tool_alt_rounded, size: 18, color: BC.inkSoft),
          const SizedBox(width: 6),
          Expanded(child: Text(l.moveMapToAdjust, style: const TextStyle(color: BC.inkSoft))),
          if (_lookingUp) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: _locating ? null : _useGps,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: _locating ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)) : const Icon(Icons.my_location_rounded),
          label: Text(_point != null ? l.locationCaptured : l.useMyLocation, style: const TextStyle(fontSize: 17)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _area,
          style: const TextStyle(fontSize: 17),
          decoration: InputDecoration(labelText: l.area, prefixIcon: const Icon(Icons.map_rounded)),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _address,
          minLines: 2,
          maxLines: 3,
          style: const TextStyle(fontSize: 17),
          decoration: InputDecoration(labelText: l.fullAddress, hintText: l.fullAddressHint, prefixIcon: const Icon(Icons.home_rounded)),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(l.addressPrivacy, style: const TextStyle(color: BC.inkSoft)),
        const SizedBox(height: 20),
        Text(l.startDate, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in [0, 1, 2, 3, 7])
            Builder(builder: (_) {
              final day = DateTime.now().add(Duration(days: d));
              final on = _start.day == day.day && _start.month == day.month;
              return ChoiceChip(
                selected: on,
                onSelected: (_) => setState(() => _start = day),
                label: Text(d == 0 ? l.today : (d == 1 ? l.tomorrow : '${day.day}/${day.month}'), style: const TextStyle(fontSize: 16)),
              );
            }),
          ActionChip(
            avatar: const Icon(Icons.calendar_month_rounded),
            label: BtnLabel(l.pickDate),
            onPressed: () async {
              final d = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 90)), initialDate: _start);
              if (d != null) setState(() => _start = d);
            },
          ),
        ]),
      ]);

  // ---------------------------------------------------------------- step 4
  Widget _priceStep(L l) {
    final e = _estimate;
    if (e == null) return const Center(child: CircularProgressIndicator(color: BC.brand));
    final items = (e['items'] as List).cast<Json>();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: BC.moneySoft, borderRadius: BorderRadius.circular(BC.rLg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.fairPriceTitle, style: const TextStyle(fontWeight: FontWeight.w700, color: BC.money, fontSize: 16)),
          const SizedBox(height: 6),
          FittedBox(
            child: Text('${inr(e['total_low_inr'] as num)} – ${inr(e['total_high_inr'] as num)}',
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700, color: BC.money, fontFeatures: BC.tabular)),
          ),
          const SizedBox(height: 4),
          Text(l.fairPriceSub(_area.text.trim()), style: const TextStyle(color: BC.inkSoft)),
        ]),
      ),
      const SizedBox(height: 16),
      for (final it in items)
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            minTileHeight: 72,
            leading: Icon(TradeStyle.of(it['trade'] as String).icon, color: TradeStyle.of(it['trade'] as String).color, size: 32),
            title: Text(tradeLabel(l, it['trade'] as String), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            subtitle: Text(l.basedOnJobs(it['samples'] as int)),
            trailing: Text('${inr(it['low_inr'] as num)}–${inr(it['high_inr'] as num)}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, fontFeatures: BC.tabular)),
          ),
        ),
      const SizedBox(height: 8),
      InfoBanner(icon: Icons.lock_rounded, color: BC.info, text: l.howPaymentWorks(inr(e['platform_fee_inr'] as num))),
      const SizedBox(height: 16),
      Text(l.summary, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      for (final (i, w) in _works.indexed)
        Text('${l.workN(i + 1)} · ${tradeLabel(l, w.trade)} · ${w.photos.length} 📷${w.audio != null ? ' · 🔊 ${mmss(w.audio!.seconds)}' : ''}',
            style: const TextStyle(fontSize: 16)),
      Text('📍 ${_area.text.trim()} · ${_start.day}/${_start.month}', style: const TextStyle(fontSize: 16)),
    ]);
  }
}

class _WorkCardEditor extends StatelessWidget {
  const _WorkCardEditor({required this.index, required this.draft, required this.onChanged, required this.onRecord, required this.onRetryUpload, this.onRemove});
  final int index;
  final WorkDraft draft;
  final VoidCallback onChanged, onRecord, onRetryUpload;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final s = TradeStyle.of(draft.trade);
    final a = draft.audio;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: BC.ink, borderRadius: BorderRadius.circular(8)),
              child: Text(l.workN(index + 1), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Icon(s.icon, color: s.color),
            const SizedBox(width: 4),
            Text(tradeLabel(l, draft.trade), style: TextStyle(color: s.color, fontWeight: FontWeight.w700, fontSize: 17)),
            const Spacer(),
            // Speaker chip: which work has which audio, at a glance.
            if (a != null) StatusPill(label: '🔊 ${mmss(a.seconds)}', color: BC.brandDark, bg: BC.brandSoft),
            if (onRemove != null) IconButton(onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
          ]),
          const SizedBox(height: 12),
          // Photos 1–5
          SizedBox(
            height: 84,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final (i, p) in draft.photos.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(children: [
                    ClipRRect(borderRadius: BorderRadius.circular(12), child: AppImage(p, width: 84, height: 84)),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: () {
                          draft.photos.removeAt(i);
                          onChanged();
                        },
                        child: const CircleAvatar(radius: 13, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 16, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
              if (draft.photos.length < 5)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final p = await pickPhoto(context);
                    if (p != null) {
                      draft.photos.add(p);
                      onChanged();
                    }
                  },
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: BC.line, width: 2)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.add_a_photo_rounded, color: BC.inkSoft),
                      Text('${draft.photos.length}/5', style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: draft.text,
            maxLines: 2,
            maxLength: 300,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(hintText: l.describeOptional, counterText: ''),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          // AUDIO DESCRIPTION — the prominent action.
          if (a == null)
            FilledButton.icon(
              onPressed: onRecord,
              style: FilledButton.styleFrom(backgroundColor: BC.ink),
              icon: const Icon(Icons.mic_rounded, size: 28),
              label: BtnLabel(l.recordVoiceNote),
            )
          else ...[
            AudioPlayerCard(url: a.path, durationSec: a.seconds, sizeKb: a.bytes ~/ 1024, label: l.voiceNoteRecorded(mmss(a.seconds))),
            const SizedBox(height: 6),
            Row(children: [
              if (draft.uploading)
                StatusPill(label: l.uploading, color: BC.info, bg: BC.infoSoft, icon: Icons.cloud_upload_outlined)
              else if (draft.uploadFailed)
                InkWell(
                  onTap: onRetryUpload,
                  child: StatusPill(label: l.waitingToUpload, color: const Color(0xFF92400E), bg: BC.pendingSoft, icon: Icons.cloud_off_rounded),
                )
              else
                StatusPill(label: l.uploaded, color: BC.money, bg: BC.moneySoft, icon: Icons.cloud_done_rounded),
              const Spacer(),
              TextButton.icon(onPressed: onRecord, icon: const Icon(Icons.replay_rounded), label: BtnLabel(l.recordAgain)),
            ]),
          ],
        ]),
      ),
    );
  }
}
