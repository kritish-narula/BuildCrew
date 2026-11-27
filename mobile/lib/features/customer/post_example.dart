import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';

/// "See an example": a well-written job post (photos, words, voice note) so nobody has to guess what to write.
Future<void> showPostExample(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => const _ExampleSheet(),
    );

class _ExampleSheet extends StatelessWidget {
  const _ExampleSheet();

  Widget _photo(BuildContext context, IconData icon, String caption) => Expanded(
        child: Column(children: [
          AspectRatio(
            aspectRatio: 1.2,
            child: Container(
              decoration: BoxDecoration(color: BC.closedSoft, borderRadius: BorderRadius.circular(BC.rSm), border: Border.all(color: BC.line)),
              child: Icon(icon, size: 40, color: BC.inkFaint),
            ),
          ),
          const SizedBox(height: 4),
          Text(caption, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: BC.caption),
        ]),
      );

  Widget _tip(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.check_circle_rounded, color: BC.money, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: context.tt.bodyMedium)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(l.cxExTitle, style: context.tt.titleLarge),
          const SizedBox(height: 12),
          // the sample post, drawn like the real card
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const TradeChip('plumber'),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _photo(context, Icons.water_drop_outlined, l.cxExPhoto1),
                const SizedBox(width: 10),
                _photo(context, Icons.plumbing, l.cxExPhoto2),
              ]),
              const SizedBox(height: 12),
              Text(l.cxExText, style: context.tt.bodyLarge),
              const SizedBox(height: 10),
              StatusPill(label: l.cxExVoice, color: BC.brandDark, bg: BC.brandSoft, icon: Icons.mic_rounded),
            ]),
          ),
          const SizedBox(height: 8),
          _tip(context, l.cxExTip1),
          _tip(context, l.cxExTip2),
          _tip(context, l.cxExTip3),
          const SizedBox(height: 16),
          PrimaryButton(label: l.cxGotIt, icon: Icons.check_rounded, onPressed: () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}
