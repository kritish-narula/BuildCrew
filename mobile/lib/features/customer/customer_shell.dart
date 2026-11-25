import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/app_state.dart';
import '../../core/poller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../common/chat.dart';
import '../common/profile.dart';
import '../common/update_ui.dart';
import 'customer_home.dart';
import 'contractor.dart';
import 'customer_job.dart';
import 'post_job.dart';
import 'team_job.dart';
import 'workers.dart';

/// Customer app: Home · Bookings · Messages · Profile. The shell owns the bookings list (one
/// fetch, refreshed every 4 s while the app is open, at once on resume) so Home and Bookings always agree, and the unread badge.
class CustomerShell extends StatefulWidget {
  const CustomerShell({super.key, required this.state});
  final AppState state;
  @override
  State<CustomerShell> createState() => _CustomerShellState();
}

class _CustomerShellState extends State<CustomerShell> {
  int _tab = 0;
  int _unread = 0;
  int _gen = 0; // bumped when another account signs in on the same screen (demo switch)
  List<Json>? _jobs;
  bool _failed = false;
  bool _loading = false;
  String? _uid;
  late final Poller _poller;

  AppState get _s => widget.state;

  @override
  void initState() {
    super.initState();
    _uid = _s.user?.id;
    _s.addListener(_onState);
    _reload();
    _poller = Poller(const Duration(seconds: 4), _reload)..start(); // paused in the background, immediate on resume
  }

  @override
  void dispose() {
    _poller.dispose();
    _s.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    if (_s.user?.id == _uid) {
      setState(() {}); // same account, profile data (e.g. business name) changed
      return;
    }
    // Different account on the same device → drop everything that belonged to the old one.
    setState(() {
      _uid = _s.user?.id;
      _jobs = null;
      _failed = false;
      _unread = 0;
      _tab = 0;
      _gen++;
    });
    _loading = false; // an in-flight load for the old account is discarded by the uid check
    _reload();
  }

  Future<void> _reload() async {
    if (_loading || _s.user == null) return;
    _loading = true;
    final uid = _uid;
    try {
      final jobs = await _s.api.customerJobs();
      // Jobs with a hired worker also need their detail (price, "on the way", "work finished").
      final full = await Future.wait<Json>(jobs.map<Future<Json>>((j) async {
        final st = j['status'];
        if (st == 'assigned' || st == 'in_progress') {
          try {
            return {...j, 'detail': await _s.api.customerJob(j['id'] as String)};
          } catch (_) {/* card just shows less */}
        }
        return j;
      }));
      if (!mounted || uid != _uid) return;
      setState(() {
        _jobs = full;
        _failed = false;
      });
    } catch (_) {
      if (mounted && _jobs == null) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  void _setUnread(int n) {
    if (mounted && n != _unread) setState(() => _unread = n);
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(customerRoute<void>(builder: (_) => screen));
    if (mounted) _reload();
  }

  bool get _contractor => _s.user?.isContractor == true;

  Future<void> _post({bool team = false}) async {
    final posted = await Navigator.of(context).push<bool>(customerRoute<bool>(builder: (_) => PostJobScreen(state: _s, team: team)));
    if (!mounted) return;
    // contractors: Team tab (1) for team jobs, Bookings (2) for single jobs; everyone else: Bookings (1)
    if (posted == true) setState(() => _tab = _contractor ? (team ? 1 : 2) : 1);
    _reload();
  }

  /// Team jobs have their own screen (applicants per trade, roster, pay the team).
  void _openJob(String id) {
    final j = _jobs?.where((x) => x['id'] == id).firstOrNull;
    _push(j != null && isTeamJob(j) ? TeamJobScreen(state: _s, jobId: id) : CustomerJobScreen(state: _s, jobId: id));
  }

  Future<void> _addBusiness() async {
    final l = L.of(context);
    final c = TextEditingController(text: _s.user?.orgName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.bizNameTitle),
        content: TextField(controller: c, autofocus: true, maxLength: 80, decoration: InputDecoration(hintText: l.bizNameHint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(l.save)),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await _s.api.setBusinessName(name);
      await _s.updateUser(orgName: name);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final contractor = _contractor;
    return UpdateAware(
      state: _s,
      child: CompactButtons(
        child: Scaffold(
        body: IndexedStack(index: _tab, children: [
          CustomerHomeTab(
            key: ValueKey('home$_gen'),
            state: _s,
            jobs: _jobs,
            failed: _failed,
            onReload: _reload,
            onOpenJob: _openJob,
            onPost: _post,
            onPostTeam: contractor ? () => _post(team: true) : null,
            onAddBusiness: contractor ? _addBusiness : null,
            onBrowse: () => _push(BrowseWorkersScreen(state: _s)),
            onSeeBookings: () => setState(() => _tab = contractor ? 2 : 1),
          ),
          if (contractor)
            ContractorTeamTab(
              key: ValueKey('team$_gen'),
              jobs: _jobs,
              failed: _failed,
              onReload: _reload,
              onOpenJob: _openJob,
              onPostTeam: () => _post(team: true),
            ),
          CustomerBookingsTab(
            key: ValueKey('bookings$_gen'),
            jobs: _jobs,
            failed: _failed,
            onReload: _reload,
            onOpenJob: _openJob,
            onPost: _post,
          ),
          Scaffold(
            key: ValueKey('messages$_gen'),
            appBar: AppBar(title: Text(l.messagesTitle)),
            body: ChatInboxView(state: _s, onUnread: _setUnread),
          ),
          Scaffold(
            key: ValueKey('profile$_gen'),
            appBar: AppBar(title: Text(l.navProfile)),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long_rounded),
                    title: Text(l.payments),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _push(PaymentsScreen(state: _s)),
                  ),
                ),
              ),
              Expanded(child: ProfileView(state: _s)),
            ]),
          ),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: l.navHome),
            if (contractor) NavigationDestination(icon: const Icon(Icons.groups_outlined), selectedIcon: const Icon(Icons.groups_rounded), label: l.navTeam),
            NavigationDestination(icon: const Icon(Icons.assignment_outlined), selectedIcon: const Icon(Icons.assignment_rounded), label: l.navBookings),
            NavigationDestination(
              icon: Badge(isLabelVisible: _unread > 0, label: Text(_unread > 99 ? '99+' : '$_unread'), child: const Icon(Icons.chat_bubble_outline_rounded)),
              selectedIcon: Badge(isLabelVisible: _unread > 0, label: Text(_unread > 99 ? '99+' : '$_unread'), child: const Icon(Icons.chat_bubble_rounded)),
              label: l.navMessages,
            ),
            NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: l.navProfile),
          ],
        ),
        ),
      ),
    );
  }
}
