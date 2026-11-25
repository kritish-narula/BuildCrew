import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:latlong2/latlong.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/app_state.dart';
import '../../core/demo_api.dart' show DemoPricing;
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/fair_price.dart';
import '../../widgets/maps.dart';
import '../../widgets/media.dart';
import '../../widgets/schedule.dart';

const trades = ['mason', 'plumber', 'electrician', 'carpenter', 'painter', 'helper'];

/// Post-a-job rules (also enforced by the server): at least 2 photos and 50 characters of description per work item.
const minPhotos = 2;
const minDescription = 50;

/// One "work card" = one trade with photos + text + voice note (both allowed, never either/or).
class WorkDraft {
  WorkDraft(this.trade);
  String trade;
  final List<String> photos = [];
  final text = TextEditingController();
  final transcript = TextEditingController();
  RecordedNote? audio;
  // Team jobs (contractor): how many workers of this trade, for how many days, at what daily wage.
  int headcount = 2, days = 3;
  final wage = TextEditingController();
  bool wageEdited = false;
  Json? wageSuggestion; // {low, median, high, min_wage}
  int get descLength => text.text.trim().length;
  bool get rulesMet => photos.length >= minPhotos && descLength >= minDescription;
  int? get wageInr => int.tryParse(wage.text.replaceAll(RegExp(r'[^0-9]'), ''));
  String? audioKey; // set once uploaded
  bool uploading = false, transcribing = false, uploadFailed = false;
  bool get hasContent => photos.isNotEmpty || text.text.trim().isNotEmpty || audio != null;
}

/// C2 — the core flow: 1 trades → 2 work cards → 3 place & date/time → 4 fair price → post.
/// With [team] (contractors) step 1 also asks headcount + days per trade and step 4 sets the daily wage.
class PostJobScreen extends StatefulWidget {
  const PostJobScreen({super.key, required this.state, this.team = false});
  final AppState state;
  final bool team;
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
  String? _slot = 'morning'; // morning | afternoon | evening | exact
  TimeOfDay? _time; // for an exact time
  Json? _estimate;
  bool _posting = false, _locating = false;

  String get _lang => widget.state.language ?? 'hi';

  @override
  void dispose() {
    _area.dispose();
    _address.dispose();
    super.dispose();
  }

  bool get _canNext => _blockReason(null) == null;

  /// Why Continue / Post is disabled (shown inline above the button). Null = go ahead.
  /// With [l] null only the "is it blocked" answer matters, so a placeholder is returned.
  String? _blockReason(L? l) {
    String t(String Function(L) f) => l == null ? '-' : f(l);
    switch (_step) {
      case 0:
        return _works.isEmpty ? t((l) => l.pjNeedTrade) : null;
      case 1:
        for (final (i, w) in _works.indexed) {
          if (w.photos.length < minPhotos) return t((l) => l.pjNeedPhotos(i + 1, minPhotos - w.photos.length));
          if (w.descLength < minDescription) return t((l) => l.pjNeedDesc(i + 1, minDescription, w.descLength));
        }
        if (_works.any((w) => w.uploading)) return t((l) => l.uploading);
        return null;
      case 2:
        if (_point == null || _area.text.trim().isEmpty || _address.text.trim().length < 3) return t((l) => l.pjNeedLocation);
        if (!_scheduleOk) return t((l) => l.pjNeedTime);
        return null;
      default:
        if (widget.team) {
          for (final w in _works) {
            final min = (w.wageSuggestion?['min_wage'] as num?)?.toInt() ?? DemoPricing.minWagePerDay(w.trade);
            if ((w.wageInr ?? 0) < min) return t((l) => l.teamWageBelowMin(inr(min)));
          }
        }
        return null;
    }
  }

  // ---------------------------------------------------------------- schedule (day + time)
  DateTime get _day => DateTime(_start.year, _start.month, _start.day);
  bool get _isToday {
    final n = DateTime.now();
    return _day == DateTime(n.year, n.month, n.day);
  }

  DateTime? get _scheduledFor {
    if (_slot == null) return null;
    if (_slot == 'exact') return _time == null ? null : DateTime(_day.year, _day.month, _day.day, _time!.hour, _time!.minute);
    return DateTime(_day.year, _day.month, _day.day, slotHours[_slot]!.$1);
  }

  /// Not in the past: a slot is bookable until it ends, an exact time until it has passed.
  bool get _scheduleOk {
    final at = _scheduledFor;
    if (at == null) return false;
    final now = DateTime.now();
    if (_slot == 'exact') return !at.isBefore(now.subtract(const Duration(minutes: 1)));
    return slotStillOpen(_slot!, _day, now);
  }

  void _pickDay(DateTime day) => setState(() {
        _start = day;
        if (!_scheduleOk) {
          _slot = null; // the chosen slot / time is already over on this day
          _time = null;
        }
      });

  Future<void> _pickTime() async {
    final now = TimeOfDay.now();
    final t = await showTimePicker(
      context: context,
      initialTime: _time ?? (_isToday ? TimeOfDay(hour: now.hour < 23 ? now.hour + 1 : 23, minute: 0) : const TimeOfDay(hour: 9, minute: 0)),
    );
    if (t == null || !mounted) return;
    if (DateTime(_day.year, _day.month, _day.day, t.hour, t.minute).isBefore(DateTime.now())) {
      showError(context, ApiException('err.schedule_past', ''));
      return;
    }
    setState(() {
      _slot = 'exact';
      _time = t;
    });
  }

  void _toggleTrade(String t) => setState(() {
        final i = _works.indexWhere((w) => w.trade == t);
        i >= 0 ? _works.removeAt(i) : _works.add(WorkDraft(t));
      });

  /// Team step 4: fair daily wage per trade for the job's city (prefill, never overwrites what the contractor typed).
  Future<void> _loadWages() async {
    try {
      final r = await widget.state.api.wageSuggestion(_works.map((w) => w.trade).toList(), _city.isEmpty ? null : _city);
      final byTrade = {for (final i in (r['items'] as List).cast<Json>()) i['trade'] as String: i};
      if (!mounted) return;
      setState(() {
        for (final w in _works) {
          final sug = byTrade[w.trade];
          if (sug == null) continue;
          w.wageSuggestion = sug;
          if (!w.wageEdited || w.wage.text.isEmpty) w.wage.text = '${(sug['median'] as num).toInt()}';
        }
        _estimate = {'loaded': true};
      });
    } catch (_) {
      if (mounted) setState(() => _estimate = {'loaded': true});
    }
  }

  Future<void> _next() async {
    if (_step == 2 && widget.team) {
      setState(() {
        _step = 3;
        _estimate = null;
      });
      await _loadWages();
      return;
    }
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
          if (widget.team) ...{'headcount': w.headcount, 'days': w.days, 'daily_wage_inr': w.wageInr},
        });
      }
      await widget.state.api.createJob({
        'location_lat': _point!.latitude, 'location_lng': _point!.longitude, 'address_text': _address.text.trim(),
        'city': _city.isEmpty ? _area.text.trim() : _city, 'locality': _area.text.trim(),
        'start_date': _start.toIso8601String().substring(0, 10), 'work_items': items,
        'scheduled_for': _scheduledFor!.toUtc().toIso8601String(), 'time_slot': _slot,
        if (widget.team) 'kind': 'team',
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
    final titles = [widget.team ? l.teamStepTrades : l.stepWhatWork, l.stepDescribe, l.stepWhereWhen, widget.team ? l.teamStepWages : l.stepFairPrice];
    final reason = _blockReason(l);
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.team ? l.postTeamJob : l.postJob),
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
        body: switch (_step) {
          0 => widget.team ? _teamTradesStep(l) : _tradesStep(l),
          1 => _describeStep(l),
          2 => _whereStep(l),
          _ => widget.team ? _wageStep(l) : _priceStep(l)
        },
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Why the button is grey, in plain words, right above it.
              if (reason != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.info_outline_rounded, size: 18, color: BC.pendingInk),
                    const SizedBox(width: 6),
                    Expanded(child: Text(reason, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.pendingInk, fontWeight: FontWeight.w600, fontSize: 14, height: 1.3))),
                  ]),
                ),
              _step < 3
                  ? FilledButton(onPressed: _canNext ? _next : null, child: BtnLabel(l.continueBtn))
                  : FilledButton.icon(
                      onPressed: (_posting || reason != null || (widget.team && _estimate == null)) ? null : _post,
                      icon: _posting ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)) : const Icon(Icons.send_rounded),
                      label: BtnLabel(widget.team ? l.postTeamJobNow : l.postJobNow),
                    ),
            ]),
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
          Builder(builder: (_) {
            final today = DateTime.now();
            final tomorrow = today.add(const Duration(days: 1));
            final custom = _day.isAfter(DateTime(tomorrow.year, tomorrow.month, tomorrow.day));
            return Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(selected: _isToday, onSelected: (_) => _pickDay(today), label: Text(l.today, style: const TextStyle(fontSize: 16))),
              ChoiceChip(
                selected: !_isToday && !custom,
                onSelected: (_) => _pickDay(tomorrow),
                label: Text(l.tomorrow, style: const TextStyle(fontSize: 16)),
              ),
              ChoiceChip(
                selected: custom,
                avatar: const Icon(Icons.calendar_month_rounded, size: 20),
                label: BtnLabel(custom ? '${_day.day}/${_day.month}' : l.pickDate),
                onSelected: (_) async {
                  final d = await showDatePicker(context: context, firstDate: DateTime(today.year, today.month, today.day), lastDate: today.add(const Duration(days: 90)), initialDate: _day);
                  if (d != null) _pickDay(d);
                },
              ),
            ]);
          }),
        ]),
        const SizedBox(height: 16),
        Text(l.schedTimeTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final slot in timeSlots)
            ChoiceChip(
              selected: _slot == slot,
              // slots that are already over today are disabled
              onSelected: slotStillOpen(slot, _day, DateTime.now()) ? (_) => setState(() {
                    _slot = slot;
                    _time = null;
                  }) : null,
              label: Text(slotLabel(l, slot), style: const TextStyle(fontSize: 16)),
            ),
          ChoiceChip(
            selected: _slot == 'exact',
            avatar: const Icon(Icons.access_time_rounded, size: 20),
            onSelected: (_) => _pickTime(),
            label: BtnLabel(_slot == 'exact' && _time != null ? _time!.format(context) : l.slotExact),
          ),
        ]),
        if (_isToday && !timeSlots.any((s) => slotStillOpen(s, _day, DateTime.now())))
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.schedNoSlotsToday, style: const TextStyle(color: BC.pendingInk))),
        if (_scheduledFor != null && _scheduleOk) ...[
          const SizedBox(height: 10),
          ScheduleLine(iso: _scheduledFor!.toIso8601String(), slot: _slot, color: BC.money),
        ],
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
            child: Text(inrRange(e['total_low_inr'] as num, e['total_high_inr'] as num),
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
            trailing: Text(inrRange(it['low_inr'] as num, it['high_inr'] as num),
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
      Text('📍 ${_area.text.trim()} · ${scheduleText(l, _scheduledFor?.toIso8601String(), _slot) ?? ''}', style: const TextStyle(fontSize: 16)),
    ]);
  }

  // ---------------------------------------------------------------- team: step 1 (trades + headcount + days)
  Widget _teamTradesStep(L l) => ListView(padding: const EdgeInsets.all(16), children: [
        InfoBanner(icon: Icons.groups_rounded, color: BC.info, text: l.teamPostIntro),
        const SizedBox(height: 12),
        for (final t in trades)
          Builder(builder: (ctx) {
            final i = _works.indexWhere((w) => w.trade == t);
            final on = i >= 0;
            final s = TradeStyle.of(t);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppCard(
                color: on ? s.color.withValues(alpha: 0.07) : BC.card,
                borderColor: on ? s.color : BC.line,
                onTap: on ? null : () => _toggleTrade(t),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  InkWell(
                    onTap: () => _toggleTrade(t),
                    child: Row(children: [
                      IconBadge(s.icon, color: s.color, size: 44),
                      const SizedBox(width: 12),
                      Expanded(child: Text(tradeLabel(l, t), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                      Icon(on ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded, color: on ? s.color : BC.inkFaint, size: 30),
                    ]),
                  ),
                  if (on) ...[
                    const Divider(height: 24),
                    _Stepper(label: l.teamWorkers, value: _works[i].headcount, min: 1, max: 50, onChanged: (v) => setState(() => _works[i].headcount = v)),
                    const SizedBox(height: 8),
                    _Stepper(label: l.teamDays, value: _works[i].days, min: 1, max: 90, onChanged: (v) => setState(() => _works[i].days = v)),
                  ],
                ]),
              ),
            );
          }),
      ]);

  // ---------------------------------------------------------------- team: step 4 (daily wage + cost)
  Widget _wageStep(L l) {
    if (_estimate == null) return const Center(child: CircularProgressIndicator(color: BC.brand));
    final fee = 30; // flat fee per worker (same as the server)
    var wages = 0, workers = 0;
    for (final w in _works) {
      wages += (w.wageInr ?? 0) * w.headcount * w.days;
      workers += w.headcount;
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      InfoBanner(icon: Icons.shield_rounded, color: BC.money, text: l.teamWageShield),
      const SizedBox(height: 12),
      for (final w in _works) ...[
        Builder(builder: (_) {
          final s = TradeStyle.of(w.trade);
          final sug = w.wageSuggestion;
          final min = (sug?['min_wage'] as num?)?.toInt() ?? DemoPricing.minWagePerDay(w.trade);
          final below = (w.wageInr ?? 0) < min;
          return AppCard(
            borderColor: below ? BC.danger : BC.line,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconBadge(s.icon, color: s.color, size: 40),
                const SizedBox(width: 10),
                Expanded(child: Text(tradeCount(l, tradeLabel(l, w.trade), w.headcount), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                Text(l.teamDaysShort(w.days), style: BC.subtle),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: w.wage,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                decoration: InputDecoration(labelText: l.teamDailyWage, prefixText: '₹ ', errorText: below ? l.teamWageBelowMin(inr(min)) : null, errorMaxLines: 3),
                onChanged: (_) => setState(() => w.wageEdited = true),
              ),
              if (sug != null) ...[
                const SizedBox(height: 6),
                Text(l.teamWageHint(inrRange(sug['low'] as num, sug['high'] as num), inr(min)), style: BC.subtle),
              ],
              const SizedBox(height: 8),
              Text(l.teamLineTotal(w.headcount, w.days, inr((w.wageInr ?? 0) * w.headcount * w.days)),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
            ]),
          );
        }),
        const SizedBox(height: 12),
      ],
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: BC.moneySoft, borderRadius: BorderRadius.circular(BC.rLg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.teamCostTitle, style: const TextStyle(fontWeight: FontWeight.w700, color: BC.money, fontSize: 16)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(inr(wages + fee * workers), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: BC.money, fontFeatures: BC.tabular)),
          ),
          const SizedBox(height: 4),
          Text(l.teamCostSub(inr(wages), inr(fee * workers)), style: const TextStyle(color: BC.inkSoft)),
        ]),
      ),
      const SizedBox(height: 12),
      InfoBanner(icon: Icons.lock_rounded, color: BC.info, text: l.teamRefundNote),
      const SizedBox(height: 12),
      Text('📍 ${_area.text.trim()} · ${scheduleText(l, _scheduledFor?.toIso8601String(), _slot) ?? ''}', style: const TextStyle(fontSize: 16)),
    ]);
  }
}

/// − N + control used for headcount and days.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.min, required this.max, required this.onChanged});
  final String label;
  final int value, min, max;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        IconButton.filledTonal(onPressed: value > min ? () => onChanged(value - 1) : null, icon: const Icon(Icons.remove_rounded)),
        SizedBox(width: 44, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: BC.tabular))),
        IconButton.filledTonal(onPressed: value < max ? () => onChanged(value + 1) : null, icon: const Icon(Icons.add_rounded)),
      ]);
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
          const SizedBox(height: 6),
          Row(children: [
            Icon(draft.photos.length >= minPhotos ? Icons.check_circle_rounded : Icons.photo_camera_outlined, size: 16,
                color: draft.photos.length >= minPhotos ? BC.money : BC.pendingInk),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l.pjPhotosCount(draft.photos.length, minPhotos), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: draft.photos.length >= minPhotos ? BC.money : BC.pendingInk)),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: draft.text,
            minLines: 3,
            maxLines: 5,
            maxLength: 300,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(hintText: l.pjDescHint, counterText: ''),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 4),
          // Live counter "32/50" + why we ask.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(l.pjDescHelper, style: const TextStyle(fontSize: 13, color: BC.inkSoft, height: 1.3))),
            const SizedBox(width: 8),
            Text('${draft.descLength}/$minDescription',
                style: TextStyle(fontWeight: FontWeight.w700, fontFeatures: BC.tabular, color: draft.descLength >= minDescription ? BC.money : BC.danger)),
          ]),
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
