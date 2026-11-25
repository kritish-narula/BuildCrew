import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';

/// Simple job chat between the customer and one worker who quoted. Phone numbers are never
/// exchanged here; the conversation is kept as dispute evidence.
Future<void> openChat(BuildContext context, AppState state, {required String jobId, required String withUser, required String title}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(state: state, jobId: jobId, withUser: withUser, title: title)));

/// "14:05" for today, "3 Nov" for older messages. Uses the default locale on purpose: no
/// locale data has to be initialised, so it can never throw.
String _stamp(DateTime t, {bool withDate = false}) {
  final local = t.toLocal();
  final now = DateTime.now();
  final today = local.year == now.year && local.month == now.month && local.day == now.day;
  if (today) return DateFormat('HH:mm').format(local);
  return withDate ? DateFormat('d MMM, HH:mm').format(local) : DateFormat('d MMM').format(local);
}

DateTime? _parse(Object? v) => v is String ? DateTime.tryParse(v) : null;

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).take(2);
  final s = parts.map((p) => String.fromCharCode(p.runes.first)).join().toUpperCase();
  return s.isEmpty ? '?' : s;
}

class _Pending {
  _Pending(this.body) : at = DateTime.now();
  final String body;
  final DateTime at;
  bool failed = false;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.state, required this.jobId, required this.withUser, required this.title});
  final AppState state;
  final String jobId, withUser, title;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  List<Json> _msgs = [];
  final List<_Pending> _pending = [];
  bool _loading = true;
  Timer? _timer;
  int _seq = 0; // each fetch gets a number; an older fetch finishing late is ignored
  int _applied = 0;

  @override
  void initState() {
    super.initState();
    _load(silent: false);
    // The other side's messages arrive by polling (same for demo and the real backend).
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = true}) async {
    final seq = ++_seq;
    try {
      final m = await widget.state.api.chat(widget.jobId, widget.withUser);
      if (!mounted || seq < _applied) return;
      _applied = seq;
      setState(() {
        _msgs = m;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (!silent) showError(context, e);
    }
  }

  void _toBottom() {
    // The list is reversed, so "newest" is offset 0.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Future<void> _send([_Pending? retry]) async {
    final text = retry?.body ?? _c.text.trim();
    if (text.isEmpty) return;
    final p = retry ?? _Pending(text);
    p.failed = false;
    setState(() {
      if (retry == null) _pending.add(p);
    });
    if (retry == null) _c.clear();
    _toBottom();
    try {
      await widget.state.api.sendChat(widget.jobId, widget.withUser, text);
      final seq = ++_seq;
      final m = await widget.state.api.chat(widget.jobId, widget.withUser);
      if (!mounted) return;
      setState(() {
        if (seq >= _applied) {
          _applied = seq;
          _msgs = m;
        }
        _pending.remove(p); // the real message is in the list now → never shown twice
      });
      _toBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => p.failed = true);
      showError(context, e);
    }
  }

  Widget _bubble(L l, {required bool mine, required String body, required DateTime? at, _Pending? pending}) {
    final fg = mine ? Colors.white : BC.ink;
    final sub = mine ? Colors.white70 : BC.inkFaint;
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      decoration: BoxDecoration(
        color: pending?.failed == true ? BC.danger : (mine ? BC.brand : Colors.white),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
        border: mine ? null : Border.all(color: BC.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Align(alignment: Alignment.centerLeft, child: Text(body, style: TextStyle(fontSize: 16, height: 1.3, color: fg))),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (pending != null) ...[
            Icon(pending.failed ? Icons.error_outline_rounded : Icons.schedule_rounded, size: 12, color: sub),
            const SizedBox(width: 3),
            Text(pending.failed ? l.chatNotSent : l.chatSending, style: TextStyle(fontSize: 11, color: sub)),
          ] else if (at != null)
            Text(_stamp(at, withDate: true), style: TextStyle(fontSize: 11, color: sub)),
        ]),
      ]),
    );
    final aligned = Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: bubble);
    if (pending != null && pending.failed) return GestureDetector(onTap: () => _send(pending), child: aligned);
    return aligned;
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    // Server messages first, then ones still on their way (shown once; removed as soon as the
    // server list contains them).
    final total = _msgs.length + _pending.length;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: BC.brand))
              : total == 0
                  ? ListView(children: [EmptyState(icon: Icons.chat_bubble_outline_rounded, text: l.chatEmpty)])
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: total,
                      itemBuilder: (ctx, i) {
                        final idx = total - 1 - i;
                        if (idx >= _msgs.length) {
                          final p = _pending[idx - _msgs.length];
                          return _bubble(l, mine: true, body: p.body, at: p.at, pending: p);
                        }
                        final m = _msgs[idx];
                        return _bubble(l, mine: m['mine'] == true, body: (m['body'] as String?) ?? '', at: _parse(m['at']));
                      },
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _c,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 1000,
                  buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
                  decoration: InputDecoration(hintText: l.typeMessage, contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                style: IconButton.styleFrom(backgroundColor: BC.brand, minimumSize: const Size(52, 52)),
                icon: const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Inbox shortcut with an unread badge — put it in any app bar. Polls every ~15 s.
class ChatInboxButton extends StatefulWidget {
  const ChatInboxButton({super.key, required this.state});
  final AppState state;
  @override
  State<ChatInboxButton> createState() => _ChatInboxButtonState();
}

class _ChatInboxButtonState extends State<ChatInboxButton> {
  int _unread = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final t = await widget.state.api.chatThreads();
      final n = t.fold<int>(0, (s, x) => s + ((x['unread'] as num?)?.toInt() ?? 0));
      if (mounted && n != _unread) setState(() => _unread = n);
    } catch (_) {/* badge is best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return IconButton(
      tooltip: l.messagesTitle,
      iconSize: 28,
      onPressed: () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInboxScreen(state: widget.state)));
        _poll();
      },
      icon: Badge(
        isLabelVisible: _unread > 0,
        label: Text(_unread > 99 ? '99+' : '$_unread'),
        backgroundColor: BC.danger,
        child: const Icon(Icons.chat_bubble_outline_rounded),
      ),
    );
  }
}

class ChatInboxScreen extends StatelessWidget {
  const ChatInboxScreen({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(L.of(context).messagesTitle)),
        body: ChatInboxView(state: state),
      );
}

/// The list of conversations (both roles). Refreshes every 6 s; [onUnread] reports the total so
/// a shell can show a badge on its Messages tab.
class ChatInboxView extends StatefulWidget {
  const ChatInboxView({super.key, required this.state, this.onUnread});
  final AppState state;
  final ValueChanged<int>? onUnread;
  @override
  State<ChatInboxView> createState() => _ChatInboxViewState();
}

class _ChatInboxViewState extends State<ChatInboxView> {
  List<Json>? _threads;
  bool _error = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await widget.state.api.chatThreads();
      if (!mounted) return;
      setState(() {
        _threads = t;
        _error = false;
      });
      widget.onUnread?.call(t.fold<int>(0, (s, x) => s + ((x['unread'] as num?)?.toInt() ?? 0)));
    } catch (_) {
      if (mounted && _threads == null) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final threads = _threads;
    if (threads == null) {
      return _error
          ? Center(child: OutlinedButton(onPressed: _load, child: Text(l.retry)))
          : const Center(child: CircularProgressIndicator(color: BC.brand));
    }
    if (threads.isEmpty) {
      return RefreshIndicator(
        color: BC.brand,
        onRefresh: _load,
        child: ListView(children: [EmptyState(icon: Icons.forum_outlined, text: l.messagesEmpty)]),
      );
    }
    return RefreshIndicator(
      color: BC.brand,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: threads.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          final t = threads[i];
          final unread = (t['unread'] as num?)?.toInt() ?? 0;
          final name = (t['with_name'] as String?) ?? '';
          final trades = ((t['trades'] as List?) ?? const []).cast<String>().map((x) => tradeLabel(l, x)).join(', ');
          final at = _parse(t['last_at']);
          return Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async {
                await openChat(context, widget.state, jobId: t['job_id'] as String, withUser: t['with_user'] as String, title: name);
                _load();
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: BC.brandSoft,
                    child: Text(_initials(name), style: const TextStyle(color: BC.brandDark, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text(name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w600)),
                        ),
                        if (at != null) Text(_stamp(at), style: TextStyle(fontSize: 12, color: unread > 0 ? BC.brandDark : BC.inkFaint)),
                      ]),
                      Text('$trades · ${t['locality'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: BC.inkSoft)),
                      const SizedBox(height: 2),
                      Row(children: [
                        Expanded(
                          child: Text((t['last_body'] as String?) ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 15, color: unread > 0 ? BC.ink : BC.inkSoft, fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400)),
                        ),
                        if (unread > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(color: BC.brand, borderRadius: BorderRadius.circular(999)),
                            child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                          ),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}
