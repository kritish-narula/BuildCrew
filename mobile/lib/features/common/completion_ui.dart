import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../../widgets/media.dart';

/// Shared by the worker and the customer app: the "work finished → confirm / send back / dispute" flow.

const reworkReasonCodes = ['incomplete', 'poor_quality', 'damage', 'not_came', 'other'];

String reworkReasonLabel(L l, String code) => switch (code) {
      'incomplete' => l.reasonIncomplete,
      'poor_quality' => l.reasonPoorQuality,
      'damage' => l.reasonDamage,
      'not_came' => l.reasonNotCame,
      _ => l.reasonOther,
    };

/// Whole hours left until [iso] (rounded up, never negative). null when [iso] is null/unparseable.
int? hoursUntil(String? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso);
  if (t == null) return null;
  final mins = t.difference(DateTime.now()).inMinutes;
  return mins <= 0 ? 0 : (mins / 60).ceil();
}

String stampOf(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day}/${d.month} ${two(d.hour)}:${two(d.minute)}';
}

/// Row of small tappable thumbnails (opens the full-screen gallery on tap).
class ThumbRow extends StatelessWidget {
  const ThumbRow(this.photos, {super.key, this.size = 64});
  final List<String> photos;
  final double size;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, p) in photos.indexed)
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                body: PageView.builder(
                  controller: PageController(initialPage: i),
                  itemCount: photos.length,
                  itemBuilder: (_, k) => InteractiveViewer(child: AppImage(photos[k], fit: BoxFit.contain)),
                ),
              ),
            )),
            child: ClipRRect(borderRadius: BorderRadius.circular(BC.rSm), child: AppImage(p, width: size, height: size)),
          ),
      ]);
}

/// "Before" (the job's photos) next to "After" (the worker's proof).
class BeforeAfter extends StatelessWidget {
  const BeforeAfter({super.key, required this.before, required this.after});
  final List<String> before, after;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    Widget col(String title, List<String> photos, Color color, String empty) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
            const SizedBox(height: 8),
            if (photos.isEmpty)
              Container(
                height: 120,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: BC.closedSoft, borderRadius: BorderRadius.circular(BC.r)),
                child: Text(empty, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis, style: BC.caption),
              )
            else
              PhotoGallery(photos: photos, height: 150),
          ]),
        );
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      col(l.beforePhotos, before, BC.inkSoft, l.noBeforePhotos),
      const SizedBox(width: 10),
      col(l.afterPhotos, after, BC.money, l.noAfterPhotos),
    ]);
  }
}

/// Add / remove up to [max] photos (camera or gallery).
class PhotoPickerRow extends StatelessWidget {
  const PhotoPickerRow({super.key, required this.photos, required this.onChanged, this.max = 5});
  final List<String> photos;
  final ValueChanged<List<String>> onChanged;
  final int max;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final p in photos)
        Stack(clipBehavior: Clip.none, children: [
          ClipRRect(borderRadius: BorderRadius.circular(BC.rSm), child: AppImage(p, width: 72, height: 72)),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: () => onChanged([...photos]..remove(p)),
              child: const CircleAvatar(radius: 12, backgroundColor: BC.ink, child: Icon(Icons.close_rounded, size: 16, color: Colors.white)),
            ),
          ),
        ]),
      if (photos.length < max)
        InkWell(
          borderRadius: BorderRadius.circular(BC.rSm),
          onTap: () async {
            final p = await pickPhoto(context);
            if (p != null) onChanged([...photos, p]);
          },
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
                color: BC.brandSoft, borderRadius: BorderRadius.circular(BC.rSm), border: Border.all(color: BC.brand.withValues(alpha: 0.4))),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.add_a_photo_rounded, color: BC.brandDark),
              Text(l.addPhotoBtn, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: BC.brandDark, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
    ]);
  }
}

/// Reason chips (read-only) for a send-back.
class ReasonChips extends StatelessWidget {
  const ReasonChips(this.reasons, {super.key, this.color = BC.danger});
  final List<String> reasons;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final r in reasons) StatusPill(label: reworkReasonLabel(l, r), color: color, bg: color.withValues(alpha: 0.1)),
    ]);
  }
}

/// History of the job's completion: done → sent back (reason) → done again → confirmed / auto / dispute.
class CompletionTimeline extends StatelessWidget {
  const CompletionTimeline({super.key, required this.events});
  final List<Json> events;

  (String, IconData, Color) _look(L l, Json e) {
    final reason = ((e['reasons'] as List?) ?? const []).cast<String>().firstOrNull;
    return switch (e['kind']) {
      'worker_done' => (l.tlWorkerDone, Icons.task_alt_rounded, BC.info),
      'rework_requested' => (l.tlReworkRequested, Icons.replay_rounded, BC.danger),
      'confirmed' => (l.tlConfirmed, Icons.verified_rounded, BC.money),
      'auto_confirmed' => (l.tlAutoConfirmed, Icons.timer_rounded, BC.money),
      'auto_rated' => (l.tlAutoRated, Icons.timer_rounded, BC.money),
      'disputed' => (l.tlDisputed, Icons.gavel_rounded, BC.danger),
      'dispute_resolved' => (l.tlDisputeResolved, Icons.balance_rounded, BC.money),
      'released' => (
          switch (reason) {
            'worker_withdrew' => l.tlRelWorkerWithdrew,
            'no_show' => l.tlRelNoShow,
            'cancelled' => l.tlRelCancelled,
            _ => l.tlRelCustomerChanged,
          },
          Icons.logout_rounded,
          BC.pendingInk
        ),
      _ => ('', Icons.circle, BC.inkFaint),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox.shrink();
    final l = L.of(context);
    return AppCard(
      padding: const EdgeInsets.all(BC.pad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.tlTitle, style: context.tt.titleMedium),
        const SizedBox(height: 10),
        for (final (i, e) in events.indexed)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 28,
                child: Column(children: [
                  Icon(_look(l, e).$2, size: 20, color: _look(l, e).$3),
                  if (i < events.length - 1) Expanded(child: Container(width: 2, color: BC.line)),
                ]),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_look(l, e).$1, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.3)),
                    Text(stampOf(e['at'] as String), style: BC.caption),
                    if (e['kind'] == 'rework_requested' && ((e['reasons'] as List?) ?? const []).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      ReasonChips(((e['reasons'] as List).cast<String>())),
                    ],
                    if (e['kind'] != 'released' && e['kind'] != 'disputed' && ((e['note'] as String?) ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(e['note'] as String, maxLines: 4, overflow: TextOverflow.ellipsis, style: BC.subtle),
                    ],
                    if (((e['photos'] as List?) ?? const []).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      ThumbRow(((e['photos'] as List).cast<String>()), size: 52),
                    ],
                  ]),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Demo only: the owner cannot wait 48 hours, so this pretends time has passed (no-op button in production).
class DemoTimeSkip extends StatefulWidget {
  const DemoTimeSkip({super.key, required this.state, required this.jobId, required this.label, required this.by, required this.onDone});
  final AppState state;
  final String jobId, label;
  final Duration by;
  final Future<void> Function() onDone;
  @override
  State<DemoTimeSkip> createState() => _DemoTimeSkipState();
}

class _DemoTimeSkipState extends State<DemoTimeSkip> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    if (!widget.state.isDemo) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: SecondaryButton(
        expand: false,
        compact: true,
        icon: Icons.fast_forward_rounded,
        label: widget.label,
        onPressed: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.state.api.demoSkipTime(widget.jobId, widget.by);
                  await widget.onDone();
                } catch (e) {
                  if (mounted) showError(context, e);
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
      ),
    );
  }
}

// ---------------------------------------------------------------- sheets

/// Uploads local photo paths (server keys / demo paths pass through unchanged).
Future<List<String>> uploadPhotos(Api api, List<String> paths) async => [
      for (final p in paths) (await api.upload('photo', p))['key'] as String,
    ];

class FinishWorkResult {
  const FinishWorkResult(this.photos, this.note);
  final List<String> photos;
  final String? note;
}

/// Worker: "after" proof photos (at least 1) + optional note.
Future<FinishWorkResult?> showFinishWorkSheet(BuildContext context) => showModalBottomSheet<FinishWorkResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _FinishSheet(),
    );

class _FinishSheet extends StatefulWidget {
  const _FinishSheet();
  @override
  State<_FinishSheet> createState() => _FinishSheetState();
}

class _FinishSheetState extends State<_FinishSheet> {
  List<String> _photos = [];
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.finishTitle, style: context.tt.titleLarge),
            const SizedBox(height: 6),
            Text(l.finishHint, style: BC.subtle),
            const SizedBox(height: 14),
            PhotoPickerRow(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
            const SizedBox(height: 14),
            TextField(controller: _note, maxLines: 2, maxLength: 300, decoration: InputDecoration(hintText: l.finishNoteHint)),
            const SizedBox(height: 6),
            PrimaryButton(
              big: true,
              color: BC.money,
              icon: Icons.task_alt_rounded,
              label: _photos.isEmpty ? l.finishNeedPhoto : l.finishSend,
              onPressed: _photos.isEmpty
                  ? null
                  : () => Navigator.pop(context, FinishWorkResult(_photos, _note.text.trim().isEmpty ? null : _note.text.trim())),
            ),
          ]),
        ),
      ),
    );
  }
}

class SendBackResult {
  const SendBackResult(this.reasons, this.note, this.photos);
  final List<String> reasons;
  final String? note;
  final List<String> photos;
}

/// Customer: why is it not done? [left] = send-backs still available (0 → this one goes to support).
Future<SendBackResult?> showSendBackSheet(BuildContext context, {required int left}) => showModalBottomSheet<SendBackResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SendBackSheet(left: left),
    );

class _SendBackSheet extends StatefulWidget {
  const _SendBackSheet({required this.left});
  final int left;
  @override
  State<_SendBackSheet> createState() => _SendBackSheetState();
}

class _SendBackSheetState extends State<_SendBackSheet> {
  final Set<String> _reasons = {};
  List<String> _photos = [];
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final last = widget.left <= 0;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.sendBackTitle, style: context.tt.titleLarge),
            const SizedBox(height: 10),
            InfoBanner(
              icon: last ? Icons.gavel_rounded : Icons.info_outline_rounded,
              color: last ? BC.danger : BC.info,
              text: last ? l.sendBackLast : l.sendBackLeft(widget.left),
            ),
            const SizedBox(height: 14),
            Text(l.sendBackPick, style: context.tt.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in reworkReasonCodes)
                FilterChip(
                  label: Text(reworkReasonLabel(l, r), maxLines: 2, overflow: TextOverflow.ellipsis),
                  selected: _reasons.contains(r),
                  showCheckmark: true,
                  onSelected: (on) => setState(() => on ? _reasons.add(r) : _reasons.remove(r)),
                ),
            ]),
            const SizedBox(height: 14),
            TextField(controller: _note, maxLines: 3, maxLength: 500, decoration: InputDecoration(hintText: l.sendBackNote)),
            const SizedBox(height: 4),
            Text(l.sendBackPhotosHint, style: BC.caption),
            const SizedBox(height: 8),
            PhotoPickerRow(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
            const SizedBox(height: 16),
            PrimaryButton(
              color: last ? BC.danger : BC.brand,
              icon: last ? Icons.gavel_rounded : Icons.replay_rounded,
              label: last ? l.sendBackSupportSubmit : l.sendBackSubmit,
              onPressed: _reasons.isEmpty
                  ? null
                  : () => Navigator.pop(context, SendBackResult(reworkReasonCodes.where(_reasons.contains).toList(),
                      _note.text.trim().isEmpty ? null : _note.text.trim(), _photos)),
            ),
          ]),
        ),
      ),
    );
  }
}
