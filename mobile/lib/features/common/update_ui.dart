import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../core/updater.dart';
import '../../l10n/gen/app_localizations.dart';

/// Wraps the signed-in shells. Checks for updates on open and on every return to the app,
/// posts a system notification once per version, shows an in-app banner, and opens the
/// update sheet when the notification is tapped. A *required* update (security fix) opens a
/// sheet that can't be dismissed.
class UpdateAware extends StatefulWidget {
  const UpdateAware({super.key, required this.child, required this.state});
  final Widget child;
  final AppState state;
  @override
  State<UpdateAware> createState() => _UpdateAwareState();
}

class _UpdateAwareState extends State<UpdateAware> with WidgetsBindingObserver {
  final u = Updater.instance;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    u.addListener(_onUpdater);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await u.requestNotificationPermission();
      await _check();
      _onUpdater();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    u.removeListener(_onUpdater);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      u.onResume();
      _check();
    }
  }

  Future<void> _check() async {
    final info = await u.check();
    if (info != null && mounted) {
      final l = L.of(context);
      await u.notifyOnce(l.notifUpdateTitle, l.notifUpdateBody);
    }
  }

  void _onUpdater() {
    if (!mounted) return;
    setState(() {});
    final info = u.available;
    if (info != null && !_sheetOpen && (u.openSheetRequested || info.required)) {
      u.consumeSheetRequest();
      _open();
    }
  }

  Future<void> _open() async {
    _sheetOpen = true;
    await showUpdateSheet(context, widget.state.language ?? 'hi');
    _sheetOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    final info = u.available;
    return Column(children: [
      if (info != null)
        Material(
          color: BC.ink,
          child: SafeArea(
            bottom: false,
            child: InkWell(
              onTap: _open,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(children: [
                  const Icon(Icons.system_update_rounded, color: BC.pending, size: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('${L.of(context).updateAvailableTitle} · ${info.sizeLabel}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  FilledButton(
                    onPressed: _open,
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 16)),
                    child: Text(L.of(context).updateNow, style: const TextStyle(fontSize: 14)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: info != null, child: widget.child)),
    ]);
  }
}

Future<void> showUpdateSheet(BuildContext context, String lang) {
  final u = Updater.instance;
  final info = u.available;
  if (info == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: !info.required,
    enableDrag: !info.required,
    showDragHandle: !info.required,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => PopScope(
      canPop: !info.required,
      child: ListenableBuilder(
        listenable: u,
        builder: (ctx, _) => _UpdateSheetBody(info: info, lang: lang),
      ),
    ),
  );
}

class _UpdateSheetBody extends StatelessWidget {
  const _UpdateSheetBody({required this.info, required this.lang});
  final UpdateInfo info;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final u = Updater.instance;
    final notes = info.notesFor(lang);
    final busy = u.stage == UpdateStage.downloading || u.stage == UpdateStage.verifying || u.stage == UpdateStage.installing;

    Widget status() => switch (u.stage) {
          UpdateStage.downloading => _progress(l.updateDownloading((u.progress * 100).round()), u.progress),
          UpdateStage.verifying => _progress(l.updateVerifying, null),
          UpdateStage.installing => _note(Icons.touch_app_rounded, l.updateInstalling, BC.info),
          UpdateStage.failed => _note(Icons.wifi_off_rounded, l.updateFailed, BC.danger),
          UpdateStage.tampered => _note(Icons.gpp_bad_rounded, l.updateTampered, BC.danger),
          UpdateStage.needsPermission => _note(Icons.admin_panel_settings_rounded, l.updatePermissionBody, BC.brandDark),
          _ => const SizedBox.shrink(),
        };

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, info.required ? 28 : 4, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: BC.brandSoft, borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.rocket_launch_rounded, color: BC.brandDark, size: 30),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.updateAvailableTitle, style: Theme.of(context).textTheme.headlineSmall),
                Text('v${u.currentVersion} → v${info.versionName}', style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          if (info.required) _note(Icons.shield_rounded, l.updateRequired, BC.danger),
          Text(l.updateAvailableBody(info.sizeLabel), style: const TextStyle(fontSize: 16, color: BC.inkSoft)),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: BC.bg, borderRadius: BorderRadius.circular(BC.r)),
              child: Text(notes, style: const TextStyle(fontSize: 15, height: 1.5)),
            ),
          ],
          const SizedBox(height: 16),
          status(),
          const SizedBox(height: 8),
          if (u.stage == UpdateStage.needsPermission)
            FilledButton.icon(
              onPressed: u.openInstallPermissionSettings, // continues by itself when the user comes back
              icon: const Icon(Icons.settings_rounded),
              label: Text(l.openSettings),
            )
          else
            FilledButton.icon(
              onPressed: busy ? null : u.start,
              icon: const Icon(Icons.download_rounded),
              label: Text(u.stage == UpdateStage.failed || u.stage == UpdateStage.tampered ? l.retry : l.updateNow),
            ),
          if (u.stage == UpdateStage.failed || u.stage == UpdateStage.tampered)
            TextButton.icon(
              onPressed: () => launchUrl(Uri.parse(Updater.releasePage), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_browser_rounded),
              label: Text(L.of(context).downloadFromWebsite),
            ),
          if (!info.required) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () {
                  if (busy) u.cancel();
                  Navigator.of(context).pop();
                },
                child: Text(l.updateLater, style: const TextStyle(fontSize: 16, color: BC.inkSoft)),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _progress(String label, double? value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(value: value, minHeight: 10, backgroundColor: BC.line, color: BC.money),
        ),
        const SizedBox(height: 8),
      ]);

  Widget _note(IconData icon, String text, Color color) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(BC.r)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 15, height: 1.4))),
        ]),
      );
}
