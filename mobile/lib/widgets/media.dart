import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';

// ------------------------------------------------------------------ money & small helpers
final _inr = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
String inr(num? v) => _inr.format(v ?? 0);
String mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

/// Network photo, local file (demo/offline) or placeholder — one widget for all.
class AppImage extends StatelessWidget {
  const AppImage(this.url, {super.key, this.fit = BoxFit.cover, this.width, this.height});
  final String? url;
  final BoxFit fit;
  final double? width, height;
  @override
  Widget build(BuildContext context) {
    final u = url;
    Widget ph() => Container(width: width, height: height, color: BC.closedSoft, child: const Icon(Icons.image_outlined, color: BC.inkFaint));
    if (u == null || u.isEmpty) return ph();
    if (u.startsWith('http')) {
      return Image.network(u, fit: fit, width: width, height: height, errorBuilder: (_, __, ___) => ph(),
          loadingBuilder: (_, c, p) => p == null ? c : Container(width: width, height: height, color: BC.closedSoft));
    }
    return Image.file(File(u), fit: fit, width: width, height: height, errorBuilder: (_, __, ___) => ph());
  }
}

/// S5(a) swipeable gallery with a page indicator; tap opens full screen.
class PhotoGallery extends StatefulWidget {
  const PhotoGallery({super.key, required this.photos, this.height = 220});
  final List<String> photos;
  final double height;
  @override
  State<PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<PhotoGallery> {
  int _page = 0;
  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(BC.r),
      child: SizedBox(
        height: widget.height,
        child: Stack(children: [
          PageView.builder(
            itemCount: widget.photos.length,
            onPageChanged: (p) => setState(() => _page = p),
            itemBuilder: (ctx, i) => GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  body: Center(child: InteractiveViewer(child: AppImage(widget.photos[i], fit: BoxFit.contain))),
                ),
              )),
              child: AppImage(widget.photos[i], width: double.infinity),
            ),
          ),
          if (widget.photos.length > 1)
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < widget.photos.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(color: i == _page ? Colors.white : Colors.white54, borderRadius: BorderRadius.circular(8)),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ audio playback
/// Guarantees only ONE voice note plays at a time (spec S5): starting a player pauses the rest.
class AudioHub {
  AudioHub._();
  static final instance = AudioHub._();
  AudioPlayer? _active;
  void claim(AudioPlayer p) {
    if (_active != null && !identical(_active, p)) _active!.pause();
    _active = p;
  }

  void stopAll() => _active?.pause();
}

/// Big thumb-friendly player: play/pause, progress, duration, optional "Listen in <language>".
class AudioPlayerCard extends StatefulWidget {
  const AudioPlayerCard({super.key, required this.url, required this.durationSec, this.label, this.sizeKb, this.dark = false});
  final String url;
  final int durationSec;
  final String? label;
  final int? sizeKb;
  final bool dark;
  @override
  State<AudioPlayerCard> createState() => _AudioPlayerCardState();
}

class _AudioPlayerCardState extends State<AudioPlayerCard> {
  final _p = AudioPlayer();
  bool _loaded = false, _loading = false, _failed = false;

  Future<void> _toggle() async {
    if (_p.playing) {
      await _p.pause();
      return;
    }
    try {
      if (!_loaded) {
        setState(() => _loading = true);
        // Fetched only on tap — never auto-plays, never wastes data in the feed.
        final u = widget.url;
        if (u.startsWith('asset:')) {
          await _p.setAsset(u.substring(6));
        } else if (u.startsWith('http')) {
          await _p.setUrl(u);
        } else {
          await _p.setFilePath(u);
        }
        _loaded = true;
      }
      AudioHub.instance.claim(_p);
      if (_p.processingState == ProcessingState.completed) await _p.seek(Duration.zero);
      unawaited(_p.play());
    } catch (_) {
      setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.dark ? Colors.white : BC.ink;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
      decoration: BoxDecoration(color: widget.dark ? BC.ink : BC.brandSoft, borderRadius: BorderRadius.circular(BC.rLg)),
      child: StreamBuilder<PlayerState>(
        stream: _p.playerStateStream,
        builder: (ctx, st) {
          final playing = st.data?.playing == true && st.data?.processingState != ProcessingState.completed;
          return Row(children: [
            SizedBox(
              width: 60,
              height: 60,
              child: Material(
                color: BC.brand,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _toggle,
                  child: _loading
                      ? const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                      : Icon(_failed ? Icons.error_outline : (playing ? Icons.pause_rounded : Icons.play_arrow_rounded), color: Colors.white, size: 38),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StreamBuilder<Duration>(
                stream: _p.positionStream,
                builder: (ctx, pos) {
                  final total = _p.duration?.inMilliseconds ?? widget.durationSec * 1000;
                  final at = pos.data?.inMilliseconds ?? 0;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    if (widget.label != null)
                      Text(widget.label!, style: TextStyle(fontWeight: FontWeight.w700, color: fg, fontSize: 14)),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                          value: total > 0 ? (at / total).clamp(0.0, 1.0) : 0, minHeight: 8,
                          backgroundColor: widget.dark ? Colors.white24 : Colors.white, color: BC.brandDark),
                    ),
                    const SizedBox(height: 6),
                    Text('🔊 ${mmss(at ~/ 1000)} / ${mmss(widget.durationSec)}${widget.sizeKb != null ? ' · ${widget.sizeKb} KB' : ''}',
                        style: TextStyle(color: widget.dark ? Colors.white70 : BC.inkSoft, fontWeight: FontWeight.w600, fontFeatures: BC.tabular)),
                  ]);
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ recording (customer C2)
class RecordedNote {
  RecordedNote(this.path, this.seconds, this.bytes);
  final String path;
  final int seconds, bytes;
}

/// Voice note recorder sheet: live level meter, timer, pause/resume, soft prompt at 60 s,
/// hard stop at 120 s, then Preview / Re-record / Delete / Attach.
/// Encoded as AAC-LC mono 16 kHz @ 24 kbps → a 30 s note ≈ 90 KB (voice-optimised).
Future<RecordedNote?> showRecorderSheet(BuildContext context, {int maxSeconds = 120, int softPromptSeconds = 60}) {
  return showModalBottomSheet<RecordedNote>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _RecorderSheet(maxSeconds: maxSeconds, soft: softPromptSeconds),
  );
}

class _RecorderSheet extends StatefulWidget {
  const _RecorderSheet({required this.maxSeconds, required this.soft});
  final int maxSeconds, soft;
  @override
  State<_RecorderSheet> createState() => _RecorderSheetState();
}

enum _RecState { idle, recording, paused, done }

class _RecorderSheetState extends State<_RecorderSheet> {
  final _rec = AudioRecorder();
  _RecState _state = _RecState.idle;
  int _secs = 0;
  Timer? _timer;
  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _levels = List.filled(32, 0.05, growable: true);
  String? _path;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (!await _rec.hasPermission()) {
      setState(() => _denied = true);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    _path = '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 24000, sampleRate: 16000, numChannels: 1), path: _path!);
    _secs = 0;
    _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      final v = ((a.current + 50) / 50).clamp(0.05, 1.0); // dBFS → 0..1
      setState(() => _levels
        ..removeAt(0)
        ..add(v));
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state != _RecState.recording) return;
      setState(() => _secs++);
      if (_secs == widget.soft) HapticFeedback.mediumImpact();
      if (_secs >= widget.maxSeconds) _stop();
    });
    setState(() => _state = _RecState.recording);
  }

  Future<void> _pauseResume() async {
    if (_state == _RecState.recording) {
      await _rec.pause();
      setState(() => _state = _RecState.paused);
    } else {
      await _rec.resume();
      setState(() => _state = _RecState.recording);
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    await _ampSub?.cancel();
    _path = await _rec.stop() ?? _path;
    setState(() => _state = _RecState.done);
  }

  Future<void> _discard() async {
    _timer?.cancel();
    await _ampSub?.cancel();
    if (_state == _RecState.recording || _state == _RecState.paused) await _rec.stop();
    if (_path != null && File(_path!).existsSync()) File(_path!).deleteSync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    if (_denied) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.mic_off_rounded, size: 48, color: BC.danger),
            const SizedBox(height: 12),
            Text(l.micPermission, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ]),
        ),
      );
    }
    final done = _state == _RecState.done;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(done ? l.recordPreview : (_state == _RecState.paused ? l.recordPaused : l.recording),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Text('${mmss(_secs)} / ${mmss(widget.maxSeconds)}', style: Theme.of(context).textTheme.displayMedium),
          const SizedBox(height: 12),
          if (!done)
            SizedBox(
              height: 56,
              child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                for (final v in _levels)
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      height: 56 * v,
                      decoration: BoxDecoration(
                          color: _state == _RecState.paused ? BC.inkFaint : BC.brand, borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
              ]),
            )
          else if (_path != null)
            AudioPlayerCard(url: _path!, durationSec: _secs, label: l.recordPreview),
          if (_secs >= widget.soft && !done)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(l.recordSoftPrompt, style: const TextStyle(color: BC.brandDark, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 20),
          if (!done)
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pauseResume,
                  icon: Icon(_state == _RecState.paused ? Icons.mic_rounded : Icons.pause_rounded),
                  label: Text(_state == _RecState.paused ? l.recordResume : l.recordPause),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _secs > 0 ? _stop : null,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(BC.tap)),
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(l.recordStop),
                ),
              ),
            ])
          else ...[
            FilledButton.icon(
              onPressed: () {
                final f = File(_path!);
                Navigator.pop(context, RecordedNote(_path!, _secs, f.existsSync() ? f.lengthSync() : 0));
              },
              icon: const Icon(Icons.check_rounded),
              label: Text(l.recordAttach),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    await _discard();
                    setState(() {
                      _state = _RecState.idle;
                      _levels.fillRange(0, _levels.length, 0.05);
                    });
                    await _start();
                  },
                  icon: const Icon(Icons.replay_rounded),
                  label: Text(l.recordAgain),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    await _discard();
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.delete_outline_rounded, color: BC.danger),
                  label: Text(l.delete, style: const TextStyle(color: BC.danger)),
                ),
              ),
            ]),
          ],
          if (!done)
            TextButton(
              onPressed: () async {
                await _discard();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(l.cancel, style: const TextStyle(color: BC.inkSoft)),
            ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ photos
Future<String?> pickPhoto(BuildContext context, {bool cameraOnly = false}) async {
  final l = L.of(context);
  ImageSource? src = ImageSource.camera;
  if (!cameraOnly) {
    src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(minTileHeight: 64, leading: const Icon(Icons.photo_camera_rounded, size: 30), title: Text(l.takePhoto, style: const TextStyle(fontSize: 17)),
              onTap: () => Navigator.pop(c, ImageSource.camera)),
          ListTile(minTileHeight: 64, leading: const Icon(Icons.photo_library_rounded, size: 30), title: Text(l.fromGallery, style: const TextStyle(fontSize: 17)),
              onTap: () => Navigator.pop(c, ImageSource.gallery)),
        ]),
      ),
    );
  }
  if (src == null) return null;
  // Resized + recompressed on device: ~150–300 KB per photo instead of 3–5 MB.
  final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 72,
      preferredCameraDevice: cameraOnly ? CameraDevice.front : CameraDevice.rear);
  if (x == null) return null;
  // Picker files live in the cache, which Android may clear. Keep our own copy so the photo
  // survives until it is uploaded (and, in demo mode, so another login on this phone sees it).
  final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/photos');
  await dir.create(recursive: true);
  final ext = x.path.contains('.') ? x.path.split('.').last : 'jpg';
  final kept = await File(x.path).copy('${dir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext');
  return kept.path;
}

// ------------------------------------------------------------------ ratings
class StarInput extends StatelessWidget {
  const StarInput({super.key, required this.value, required this.onChanged, this.size = 40});
  final int value;
  final ValueChanged<int> onChanged;
  final double size;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 1; i <= 5; i++)
          InkResponse(
            radius: size * 0.6,
            onTap: () {
              HapticFeedback.selectionClick();
              onChanged(i);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: i <= value ? BC.pending : BC.line),
            ),
          ),
      ]);
}

class StarBadge extends StatelessWidget {
  const StarBadge(this.rating, {super.key, this.count, this.big = false});
  final num rating;
  final int? count;
  final bool big;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.star_rounded, color: BC.pending, size: big ? 30 : 20),
        const SizedBox(width: 2),
        Text(rating == 0 ? '—' : rating.toStringAsFixed(1),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 24 : 16, fontFeatures: BC.tabular)),
        if (count != null) Text(' ($count)', style: TextStyle(color: BC.inkSoft, fontSize: big ? 16 : 14)),
      ]);
}

/// Parameter-wise rating bars (S8 / worker profile).
class RatingBars extends StatelessWidget {
  const RatingBars({super.key, required this.breakdown});
  final Map<String, dynamic> breakdown;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final rows = [
      (l.rateQuality, Icons.construction_rounded, breakdown['quality']),
      (l.rateTimeliness, Icons.schedule_rounded, breakdown['timeliness']),
      (l.rateBehaviour, Icons.sentiment_satisfied_rounded, breakdown['behaviour']),
      (l.rateValue, Icons.currency_rupee_rounded, breakdown['value_for_money']),
    ];
    return Column(children: [
      for (final (label, icon, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, size: 22, color: BC.inkSoft),
            const SizedBox(width: 10),
            SizedBox(width: 130, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: ((v as num?) ?? 0) / 5, minHeight: 10, backgroundColor: BC.closedSoft, color: BC.pending),
              ),
            ),
            const SizedBox(width: 10),
            Text(((v as num?) ?? 0).toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: BC.tabular)),
          ]),
        ),
    ]);
  }
}

// ------------------------------------------------------------------ voice number input (S5)
/// "बोलिए, कितना पैसा चाहिए?" — speech → number. Handles digits in any script plus
/// common spoken multipliers (sau/सौ/hundred, hazaar/हज़ार/thousand).
int? parseSpokenAmount(String text) {
  const devanagari = '०१२३४५६७८९', bengali = '০১২৩৪৫৬৭৮৯', gurmukhi = '੦੧੨੩੪੫੬੭੮੯', gujarati = '૦૧૨૩૪૫૬૭૮૯';
  var t = text.toLowerCase().replaceAll(',', '');
  for (final digits in [devanagari, bengali, gurmukhi, gujarati]) {
    for (var i = 0; i < 10; i++) {
      t = t.replaceAll(digits[i], '$i');
    }
  }
  final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(t);
  if (m == null) return null;
  var n = double.parse(m.group(1)!);
  if (RegExp(r'(हज़ार|हजार|hazaa?r|thousand|k\b|হাজার|వేల|వెయ్యి|ஆயிரம்|ಸಾವಿರ|ആയിരം|ਹਜ਼ਾਰ|હજાર)').hasMatch(t) && n < 1000) n *= 1000;
  if (RegExp(r'(सौ|sau|hundred|শ|వందల|நூறு|ನೂರು|നൂറ്|ਸੌ|સો)').hasMatch(t) && n < 100) n *= 100;
  return n.round();
}

class VoiceAmountButton extends StatefulWidget {
  const VoiceAmountButton({super.key, required this.lang, required this.onAmount});
  final String lang;
  final ValueChanged<int> onAmount;
  @override
  State<VoiceAmountButton> createState() => _VoiceAmountButtonState();
}

class _VoiceAmountButtonState extends State<VoiceAmountButton> {
  final _stt = SpeechToText();
  bool _listening = false;
  String _heard = '';

  Future<void> _listen() async {
    final l = L.of(context);
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    final ok = await _stt.initialize(onStatus: (s) {
      if (s == 'done' || s == 'notListening') {
        if (mounted) setState(() => _listening = false);
      }
    });
    if (!ok) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.voiceUnavailable)));
      return;
    }
    AudioHub.instance.stopAll();
    setState(() {
      _listening = true;
      _heard = '';
    });
    await _stt.listen(
      localeId: '${widget.lang}_IN',
      listenFor: const Duration(seconds: 8),
      onResult: (r) {
        setState(() => _heard = r.recognizedWords);
        final n = parseSpokenAmount(r.recognizedWords);
        if (n != null) widget.onAmount(n);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Column(children: [
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _listen,
          style: OutlinedButton.styleFrom(
            backgroundColor: _listening ? BC.brand : Colors.white,
            foregroundColor: _listening ? Colors.white : BC.ink,
            minimumSize: const Size.fromHeight(BC.tapLg),
          ),
          icon: Icon(_listening ? Icons.graphic_eq_rounded : Icons.mic_rounded, size: 28),
          label: Text(_listening ? l.listening : l.speakPrice, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ),
      ),
      if (_heard.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('“$_heard”', style: const TextStyle(color: BC.inkSoft, fontStyle: FontStyle.italic)),
        ),
    ]);
  }
}

// ------------------------------------------------------------------ async helper
/// FutureBuilder with consistent loading / error+retry states and pull-to-refresh.
class AsyncList<T> extends StatefulWidget {
  const AsyncList({super.key, required this.load, required this.builder});
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data, Future<void> Function() reload) builder;
  @override
  State<AsyncList<T>> createState() => _AsyncListState<T>();
}

class _AsyncListState<T> extends State<AsyncList<T>> {
  late Future<T> _f = widget.load();
  Future<void> reload() async {
    final f = widget.load();
    setState(() => _f = f);
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return FutureBuilder<T>(
      future: _f,
      builder: (ctx, s) {
        if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: BC.brand));
        if (s.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.wifi_off_rounded, size: 64, color: BC.inkFaint),
                const SizedBox(height: 12),
                Text(l.errorNetwork, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: reload, child: Text(l.retry)),
              ]),
            ),
          );
        }
        return RefreshIndicator(color: BC.brand, onRefresh: reload, child: widget.builder(ctx, s.data as T, reload));
      },
    );
  }
}
