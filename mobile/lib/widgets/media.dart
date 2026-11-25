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
import 'common.dart';

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
    final page = _page.clamp(0, widget.photos.length - 1);
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
          if (widget.photos.length > 1) ...[
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(99)),
                child: Text('${page + 1}/${widget.photos.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, height: 1.3)),
              ),
            ),
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < widget.photos.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == page ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(color: i == page ? Colors.white : Colors.white54, borderRadius: BorderRadius.circular(8)),
                  ),
              ]),
            ),
          ],
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

  /// A player that is being disposed must not stay registered.
  void release(AudioPlayer p) {
    if (identical(_active, p)) _active = null;
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
    if (_loading) return;
    if (_p.playing) {
      await _p.pause();
      return;
    }
    try {
      if (!_loaded) {
        setState(() {
          _loading = true;
          _failed = false;
        });
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
      if (!mounted) return;
      AudioHub.instance.claim(_p);
      if (_p.processingState == ProcessingState.completed) await _p.seek(Duration.zero);
      unawaited(_p.play());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    AudioHub.instance.release(_p);
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark;
    final fg = dark ? Colors.white : BC.ink;
    final sub = dark ? Colors.white70 : BC.inkSoft;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
      decoration: BoxDecoration(
        color: dark ? BC.ink : BC.brandSoft.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(BC.rMd),
        border: dark ? null : Border.all(color: BC.brandSoft),
      ),
      child: StreamBuilder<PlayerState>(
        stream: _p.playerStateStream,
        builder: (ctx, st) {
          final playing = st.data?.playing == true && st.data?.processingState != ProcessingState.completed;
          return Row(children: [
            SizedBox(
              width: 52,
              height: 52,
              child: Material(
                color: BC.brand,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _toggle,
                  child: _loading
                      ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                      : Icon(_failed ? Icons.refresh_rounded : (playing ? Icons.pause_rounded : Icons.play_arrow_rounded), color: Colors.white, size: 32),
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
                  final meta = '${mmss(at ~/ 1000)} / ${mmss(widget.durationSec)}${widget.sizeKb != null ? ' · ${widget.sizeKb} KB' : ''}';
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    if (widget.label != null)
                      Text(widget.label!, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.labelLarge!.copyWith(color: fg)),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                          value: total > 0 ? (at / total).clamp(0.0, 1.0) : 0, minHeight: 6,
                          backgroundColor: dark ? Colors.white24 : Colors.white, color: dark ? BC.brand : BC.brandDark),
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      Icon(Icons.volume_up_rounded, size: 16, color: sub),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(meta,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: context.tt.labelMedium!.copyWith(color: sub, fontFeatures: BC.tabular)),
                      ),
                    ]),
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
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(BC.rLg))),
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
  bool _attached = false; // the file now belongs to the caller; don't delete it on dispose

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (!await _rec.hasPermission()) {
      if (mounted) setState(() => _denied = true);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    _path = '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 24000, sampleRate: 16000, numChannels: 1), path: _path!);
    if (!mounted) {
      // Sheet was closed while the recorder was starting.
      await _rec.stop();
      return;
    }
    _secs = 0;
    _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      if (!mounted) return;
      final v = ((a.current + 50) / 50).clamp(0.05, 1.0); // dBFS → 0..1
      setState(() => _levels
        ..removeAt(0)
        ..add(v));
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
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
      if (mounted) setState(() => _state = _RecState.paused);
    } else {
      await _rec.resume();
      if (mounted) setState(() => _state = _RecState.recording);
    }
  }

  Future<void> _stop() async {
    if (_state == _RecState.done) return;
    _timer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    _path = await _rec.stop() ?? _path;
    if (mounted) setState(() => _state = _RecState.done);
  }

  Future<void> _discard() async {
    _timer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    if (_state == _RecState.recording || _state == _RecState.paused) await _rec.stop();
    final p = _path;
    if (p != null && File(p).existsSync()) File(p).deleteSync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    final p = _path;
    final leftover = !_attached && p != null;
    // Stop + release the microphone, and drop an unattached recording.
    unawaited(() async {
      try {
        if (await _rec.isRecording() || await _rec.isPaused()) await _rec.stop();
        await _rec.dispose();
        if (leftover) {
          final f = File(p!);
          if (f.existsSync()) f.deleteSync();
        }
      } catch (_) {}
    }());
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
            Text(l.micPermission, textAlign: TextAlign.center, style: context.tt.bodyLarge),
            const SizedBox(height: 16),
            PrimaryButton(label: l.close, onPressed: () => Navigator.pop(context)),
          ]),
        ),
      );
    }
    final done = _state == _RecState.done;
    final title = done ? l.recordPreview : (_state == _RecState.paused ? l.recordPaused : l.recording);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_state == _RecState.recording) ...[
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: BC.danger, shape: BoxShape.circle)),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge)),
          ]),
          const SizedBox(height: 12),
          Text('${mmss(_secs)} / ${mmss(widget.maxSeconds)}', style: context.tt.displayMedium),
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
              child: Text(l.recordSoftPrompt, textAlign: TextAlign.center, style: context.tt.labelLarge!.copyWith(color: BC.brandDark)),
            ),
          const SizedBox(height: 20),
          if (!done)
            Row(children: [
              Expanded(
                child: SecondaryButton(
                  onPressed: _state == _RecState.idle ? null : _pauseResume,
                  icon: _state == _RecState.paused ? Icons.mic_rounded : Icons.pause_rounded,
                  label: _state == _RecState.paused ? l.recordResume : l.recordPause,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryButton(
                  onPressed: _secs > 0 ? _stop : null,
                  icon: Icons.stop_rounded,
                  label: l.recordStop,
                ),
              ),
            ])
          else ...[
            PrimaryButton(
              onPressed: () {
                final f = File(_path!);
                _attached = true;
                Navigator.pop(context, RecordedNote(_path!, _secs, f.existsSync() ? f.lengthSync() : 0));
              },
              icon: Icons.check_rounded,
              label: l.recordAttach,
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    await _discard();
                    if (!mounted) return;
                    setState(() {
                      _state = _RecState.idle;
                      _secs = 0;
                      _levels.fillRange(0, _levels.length, 0.05);
                    });
                    await _start();
                  },
                  icon: const Icon(Icons.replay_rounded),
                  label: BtnLabel(l.recordAgain),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: BC.danger),
                  onPressed: () async {
                    await _discard();
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: BtnLabel(l.delete),
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
              style: TextButton.styleFrom(foregroundColor: BC.inkSoft),
              child: BtnLabel(l.cancel),
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
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              minTileHeight: 60,
              leading: const IconBadge(Icons.photo_camera_rounded, color: BC.brand, size: 40),
              title: Text(l.takePhoto, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(c, ImageSource.camera)),
          ListTile(
              minTileHeight: 60,
              leading: const IconBadge(Icons.photo_library_rounded, color: BC.info, size: 40),
              title: Text(l.fromGallery, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(c, ImageSource.gallery)),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
  if (src == null) return null;
  try {
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
  } on PlatformException catch (e) {
    // Camera/gallery permission denied or camera unavailable: tell the user instead of crashing.
    if (context.mounted) showError(context, e);
    return null;
  }
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
              child: Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: i <= value ? BC.pending : const Color(0xFFD6D3D1)),
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
        Icon(Icons.star_rounded, color: BC.pending, size: big ? 28 : 18),
        const SizedBox(width: 2),
        Text(rating == 0 ? '—' : rating.toStringAsFixed(1),
            style: (big ? context.tt.headlineMedium : context.tt.titleMedium)!.copyWith(fontFeatures: BC.tabular)),
        if (count != null) Text(' ($count)', style: BC.subtle.copyWith(fontSize: big ? 15 : 13)),
      ]);
}

/// Parameter-wise rating bars (S8 / worker profile). Labels flex, so long Hindi/Tamil words
/// never overflow or clip.
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
      for (final (label, icon, raw) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, size: 20, color: BC.inkSoft),
            const SizedBox(width: 10),
            Expanded(
              flex: 5,
              child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.labelLarge),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                    value: (((raw as num?) ?? 0) / 5).clamp(0.0, 1.0).toDouble(), minHeight: 8, backgroundColor: BC.closedSoft, color: BC.pending),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 32,
              child: Text(((raw as num?) ?? 0).toStringAsFixed(1),
                  textAlign: TextAlign.end, style: context.tt.labelLarge!.copyWith(fontWeight: FontWeight.w700, fontFeatures: BC.tabular)),
            ),
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

  @override
  void dispose() {
    // Release the microphone if the screen is closed mid-listen.
    _stt.cancel();
    super.dispose();
  }

  Future<void> _listen() async {
    final l = L.of(context);
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final ok = await _stt.initialize(onStatus: (s) {
      if (s == 'done' || s == 'notListening') {
        if (mounted) setState(() => _listening = false);
      }
    });
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.voiceUnavailable)));
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
        if (!mounted) return;
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
        child: OutlinedButton(
          onPressed: _listen,
          style: OutlinedButton.styleFrom(
            backgroundColor: _listening ? BC.brand : Colors.white,
            foregroundColor: _listening ? Colors.white : BC.ink,
            side: BorderSide(color: _listening ? BC.brand : BC.line, width: 1.5),
            minimumSize: const Size.fromHeight(BC.tap),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_listening ? Icons.graphic_eq_rounded : Icons.mic_rounded, size: 24),
            const SizedBox(width: 10),
            Flexible(child: BtnLabel(_listening ? l.listening : l.speakPrice)),
          ]),
        ),
      ),
      if (_heard.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('“$_heard”', textAlign: TextAlign.center, style: BC.subtle.copyWith(fontStyle: FontStyle.italic)),
        ),
    ]);
  }
}

// ------------------------------------------------------------------ async helper
/// FutureBuilder with consistent loading / error+retry states and pull-to-refresh.
/// While reloading it keeps showing the previous data (no spinner flash, scroll is kept).
class AsyncList<T> extends StatefulWidget {
  const AsyncList({super.key, required this.load, required this.builder});
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data, Future<void> Function() reload) builder;
  @override
  State<AsyncList<T>> createState() => _AsyncListState<T>();
}

class _AsyncListState<T> extends State<AsyncList<T>> {
  T? _data;
  bool _has = false;
  late Future<T> _f = _track(widget.load());

  Future<T> _track(Future<T> f) => f.then((v) {
        _data = v;
        _has = true;
        return v;
      });

  Future<void> reload() async {
    if (!mounted) return;
    final f = _track(widget.load());
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
        final waiting = s.connectionState != ConnectionState.done;
        if (waiting && !_has) return const Center(child: CircularProgressIndicator(color: BC.brand));
        if (!waiting && s.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.wifi_off_rounded, size: 56, color: BC.inkFaint),
                const SizedBox(height: 12),
                Text(l.errorNetwork, textAlign: TextAlign.center, style: ctx.tt.bodyLarge),
                const SizedBox(height: 16),
                SecondaryButton(label: l.retry, onPressed: reload, expand: false, icon: Icons.refresh_rounded),
              ]),
            ),
          );
        }
        final data = (waiting ? _data : s.data) as T;
        return RefreshIndicator(color: BC.brand, onRefresh: reload, child: widget.builder(ctx, data, reload));
      },
    );
  }
}
