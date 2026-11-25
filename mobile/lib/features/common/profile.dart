import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_state.dart';
import '../../core/config.dart';
import '../../core/theme.dart';
import '../../core/updater.dart';
import '../../l10n/gen/app_localizations.dart';
import '../onboarding/onboarding.dart';
import 'update_ui.dart';

/// Shared profile/settings list (worker S8 gets ratings & labour card in Phase 2).
/// Language + updates + support + logout are reachable in one tap from every role.
class ProfileView extends StatelessWidget {
  const ProfileView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final u = state.user;
    final name = (u?.name?.isNotEmpty ?? false) ? u!.name! : '+91 ${u?.phone ?? ''}';
    final initials = name.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();

    Widget tile(IconData icon, Color color, String title, {String? sub, VoidCallback? onTap, Widget? trailing}) => Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r), side: const BorderSide(color: BC.line)),
          child: ListTile(
            onTap: onTap,
            minTileHeight: 72,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r)),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 14, color: BC.inkSoft)),
            trailing: trailing ?? const Icon(Icons.chevron_right_rounded, color: BC.inkFaint),
          ),
        );

    return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 32), children: [
      Row(children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: BC.brand,
          child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            Row(children: [
              const Icon(Icons.verified_rounded, size: 18, color: BC.money),
              const SizedBox(width: 4),
              Text('${u?.role == 'worker' ? l.role_worker : l.role_customer} · ${l.workerSince}',
                  style: const TextStyle(color: BC.inkSoft, fontWeight: FontWeight.w600)),
            ]),
          ]),
        ),
      ]),
      const SizedBox(height: 24),
      tile(Icons.translate_rounded, BC.brand, l.profileLanguage,
          sub: nativeName(state.language ?? 'hi'), onTap: () => context.push('/language?settings=1')),
      const SizedBox(height: 10),
      ListenableBuilder(
        listenable: Updater.instance,
        builder: (ctx, _) {
          final up = Updater.instance;
          return tile(Icons.system_update_rounded, BC.info, l.profileUpdates,
              sub: l.versionLabel(up.currentVersion),
              trailing: up.available != null
                  ? const Icon(Icons.circle, color: BC.danger, size: 12)
                  : null, onTap: () async {
            final info = await up.check(force: true);
            if (!context.mounted) return;
            if (info != null) {
              await showUpdateSheet(context, state.language ?? 'hi');
            } else {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.updateUpToDate)));
            }
          });
        },
      ),
      const SizedBox(height: 10),
      tile(Icons.support_agent_rounded, BC.money, l.profileSupport, onTap: () {
        showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(l.supportTitle),
            content: SelectableText(l.supportBody(AppConfig.supportPhone), style: const TextStyle(fontSize: 18)),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.close))],
          ),
        );
      }),
      const SizedBox(height: 10),
      tile(Icons.logout_rounded, BC.closed, l.profileLogout, onTap: state.signOut, trailing: const SizedBox.shrink()),
    ]);
  }
}
