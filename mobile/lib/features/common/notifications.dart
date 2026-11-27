import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/poller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';
import '../customer/customer_job.dart';
import '../worker/assignment_screen.dart';
import '../worker/job_detail.dart';
import 'chat.dart';

/// Bell with an unread badge for an app bar:  `actions: [NotificationBell(state: state)]`.
/// The count comes from the [SyncService] (no extra polling); tapping opens [NotificationsScreen].
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, required this.state, this.color});
  final AppState state;
  final Color? color;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: state.sync.unread,
        builder: (ctx, n, _) => IconButton(
          tooltip: L.of(ctx).notifTitle,
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => NotificationsScreen(state: state))),
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text(n > 99 ? '99+' : '$n'),
            backgroundColor: BC.danger,
            child: Icon(n > 0 ? Icons.notifications_active_rounded : Icons.notifications_none_rounded, color: color),
          ),
        ),
      );
}

IconData _icon(String kind) => switch (kind) {
      'new_job' || 'direct_request' => Icons.work_outline_rounded,
      'new_quote' || 'quote_accepted' => Icons.request_quote_outlined,
      'payment_held' || 'payment_released' || 'payout_paid' || 'refund_done' => Icons.account_balance_wallet_outlined,
      'payment_failed' => Icons.error_outline_rounded,
      'worker_on_way' => Icons.directions_bike_rounded,
      'worker_arrived' => Icons.place_rounded,
      'work_finished' || 'work_confirmed' => Icons.task_alt_rounded,
      'sent_back' || 'refix_requested' => Icons.replay_rounded,
      'dispute_opened' || 'dispute_resolved' => Icons.gavel_rounded,
      'chat_message' => Icons.chat_bubble_outline_rounded,
      _ => Icons.notifications_none_rounded,
    };

String _when(String? iso) {
  final t = DateTime.tryParse(iso ?? '')?.toLocal();
  if (t == null) return '';
  final now = DateTime.now();
  final today = t.year == now.year && t.month == now.month && t.day == now.day;
  return today ? DateFormat('HH:mm').format(t) : DateFormat('d MMM, HH:mm').format(t);
}

/// Opens a notification's deep link (`/job/:id`, `/assignment/:id?job=:jobId`, `/chat/:jobId/:withUser`).
void openNotificationLink(BuildContext context, String? link) {
  if (link == null || link.isEmpty || link == '/notifications') return;
  GoRouter.maybeOf(context)?.push(link);
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.state});
  final AppState state;
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Json>? _items;
  bool _failed = false;
  late final Poller _poller;

  @override
  void initState() {
    super.initState();
    _load();
    _poller = Poller(const Duration(seconds: 10), _load)..start(); // sync-driven: reloads when the server says so
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.state.api.notifications(limit: 60);
      if (!mounted) return;
      setState(() {
        _items = items;
        _failed = false;
      });
    } catch (_) {
      if (mounted && _items == null) setState(() => _failed = true);
    }
  }

  Future<void> _markAll() async {
    try {
      await widget.state.api.markNotificationsRead();
      widget.state.sync.unread.value = 0;
      await _load();
      widget.state.sync.pollNow();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _open(Json n) async {
    final id = n['id'] as String;
    if (n['read'] != true) {
      setState(() => n['read'] = true);
      final u = widget.state.sync.unread;
      if (u.value > 0) u.value = u.value - 1;
      widget.state.api.markNotificationsRead([id]).catchError((_) {});
    }
    openNotificationLink(context, n['link'] as String?);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final items = _items;
    final anyUnread = items?.any((n) => n['read'] != true) ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(l.notifTitle), actions: [
        if (anyUnread) TextButton(onPressed: _markAll, child: Text(l.notifMarkAll)),
      ]),
      body: items == null
          ? (_failed
              ? ListView(children: [EmptyState(icon: Icons.cloud_off_rounded, text: l.notifLoadFailed)])
              : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _load,
              child: items.isEmpty
                  ? ListView(children: [EmptyState(icon: Icons.notifications_none_rounded, text: l.notifEmpty)])
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                      itemBuilder: (ctx, i) {
                        final n = items[i];
                        final unread = n['read'] != true;
                        return Material(
                          color: unread ? BC.brandSoft.withValues(alpha: 0.5) : Colors.transparent,
                          child: InkWell(
                            onTap: () => _open(n),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                CircleAvatar(
                                  backgroundColor: unread ? BC.brand : BC.closedSoft,
                                  child: Icon(_icon('${n['kind']}'), color: unread ? Colors.white : BC.inkSoft, size: 22),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text('${n['title']}',
                                        style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w700 : FontWeight.w600)),
                                    if ('${n['body'] ?? ''}'.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text('${n['body']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BC.inkSoft, height: 1.3)),
                                      ),
                                  ]),
                                ),
                                const SizedBox(width: 8),
                                Text(_when(n['at'] as String?), style: const TextStyle(color: BC.inkFaint, fontSize: 12)),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

// ------------------------------------------------------------------ deep-link targets (see main.dart routes)

/// `/job/:id` -> the customer's job page, or the worker's job detail, depending on who is signed in.
class JobDeepLink extends StatelessWidget {
  const JobDeepLink({super.key, required this.state, required this.jobId});
  final AppState state;
  final String jobId;
  @override
  Widget build(BuildContext context) => state.user?.role == 'worker'
      ? JobDetailScreen(state: state, jobId: jobId)
      : CustomerJobScreen(state: state, jobId: jobId);
}

/// `/assignment/:id?job=:jobId` -> worker: assignment screen; customer: the job page (it shows the hire).
class AssignmentDeepLink extends StatelessWidget {
  const AssignmentDeepLink({super.key, required this.state, required this.assignmentId, this.jobId});
  final AppState state;
  final String assignmentId;
  final String? jobId;
  @override
  Widget build(BuildContext context) {
    if (state.user?.role == 'worker') return AssignmentScreen(state: state, assignmentId: assignmentId);
    if (jobId != null) return CustomerJobScreen(state: state, jobId: jobId!);
    return NotificationsScreen(state: state);
  }
}

/// `/chat/:jobId/:withUser` -> the chat thread (the title is the other person's name from the inbox).
class ChatDeepLink extends StatefulWidget {
  const ChatDeepLink({super.key, required this.state, required this.jobId, required this.withUser});
  final AppState state;
  final String jobId, withUser;
  @override
  State<ChatDeepLink> createState() => _ChatDeepLinkState();
}

class _ChatDeepLinkState extends State<ChatDeepLink> {
  String? _title;

  @override
  void initState() {
    super.initState();
    widget.state.api.chatThreads().then((ts) {
      final t = ts.where((t) => t['job_id'] == widget.jobId && t['with_user'] == widget.withUser).firstOrNull;
      if (mounted) setState(() => _title = (t?['with_name'] as String?) ?? '');
    }).catchError((_) {
      if (mounted) setState(() => _title = '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _title;
    if (t == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return ChatScreen(state: widget.state, jobId: widget.jobId, withUser: widget.withUser, title: t.isEmpty ? L.of(context).chat : t);
  }
}
