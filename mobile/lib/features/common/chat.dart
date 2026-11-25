import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/common.dart';

/// Simple job chat between the customer and one worker who quoted. Phone numbers are never
/// exchanged here; the conversation is kept as dispute evidence.
Future<void> openChat(BuildContext context, AppState state, {required String jobId, required String withUser, required String title}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(state: state, jobId: jobId, withUser: withUser, title: title)));

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.state, required this.jobId, required this.withUser, required this.title});
  final AppState state;
  final String jobId, withUser, title;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _c = TextEditingController();
  List<Json> _msgs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await widget.state.api.chat(widget.jobId, widget.withUser);
      if (mounted) setState(() => _msgs = m);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty) return;
    _c.clear();
    setState(() => _msgs = [..._msgs, {'mine': true, 'body': text, 'at': DateTime.now().toIso8601String()}]);
    try {
      await widget.state.api.sendChat(widget.jobId, widget.withUser, text);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: BC.brand))
              : _msgs.isEmpty
                  ? EmptyState(icon: Icons.chat_bubble_outline_rounded, text: l.chatEmpty)
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: _msgs.length,
                      itemBuilder: (ctx, i) {
                        final m = _msgs[_msgs.length - 1 - i];
                        final mine = m['mine'] == true;
                        return Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              color: mine ? BC.brand : Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: mine ? null : Border.all(color: BC.line),
                            ),
                            child: Text(m['body'] as String, style: TextStyle(fontSize: 16, color: mine ? Colors.white : BC.ink)),
                          ),
                        );
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
                  decoration: InputDecoration(hintText: l.typeMessage, contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                style: IconButton.styleFrom(backgroundColor: BC.brand, minimumSize: const Size(56, 56)),
                icon: const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
