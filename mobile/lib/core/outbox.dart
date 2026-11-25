import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Offline queue for the worker's two "must not get lost" actions: bids and attendance.
///
/// How it works:
///  1. Every action gets a random `client_ref` when the worker taps the button.
///  2. We try to send immediately. On a NETWORK error the action is saved here (on disk) and
///     the UI shows "Saved. Will send when network returns." plus a pending chip.
///  3. [flush] retries in order on app resume, every 30 s, and after any successful call.
///  4. The server de-duplicates by client_ref, so a retry after a timeout that actually
///     reached the server can never create a duplicate bid or a second check-in.
/// Business errors (job closed, etc.) are NOT retried — they are dropped and reported.
class Outbox extends ChangeNotifier {
  Outbox._();
  static final instance = Outbox._();
  static const _key = 'outbox_v1';

  late Api _api;
  final List<Json> _items = [];
  Timer? _timer;
  bool _flushing = false;

  List<Json> get items => List.unmodifiable(_items);
  int get pending => _items.length;
  bool hasPendingFor(String type, String id) => _items.any((i) => i['type'] == type && i['ref_id'] == id);

  bool _ready = false;

  Future<void> init(Api api) async {
    _api = api;
    if (_ready) return flush();
    _ready = true;
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw != null) _items.addAll((jsonDecode(raw) as List).cast<Map>().map((e) => e.cast<String, dynamic>()));
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => flush());
    unawaited(flush());
  }

  static String newRef() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Returns true if sent now, false if queued for later. Throws for business errors.
  Future<bool> bid(String jobId, int priceInr) => _run({'type': 'bid', 'ref_id': jobId, 'job_id': jobId, 'price_inr': priceInr, 'client_ref': newRef()});

  Future<bool> attendance(Json body) => _run({'type': 'attendance', 'ref_id': body['assignment_id'], ...body, 'client_ref': newRef(),
        'at': DateTime.now().toUtc().toIso8601String()}); // original time is preserved when replayed

  Future<bool> _run(Json op) async {
    try {
      await _send(op);
      unawaited(flush());
      return true;
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      _items.add(op);
      await _persist();
      notifyListeners();
      return false;
    }
  }

  Future<void> _send(Json op) async {
    switch (op['type']) {
      case 'bid':
        await _api.placeBid(op['job_id'] as String, op['price_inr'] as int, op['client_ref'] as String);
      case 'attendance':
        await _api.attendance({...op, 'offline': op['queued'] == true}..remove('type')..remove('ref_id')..remove('queued'));
    }
  }

  Future<void> flush() async {
    if (_flushing || _items.isEmpty) return;
    _flushing = true;
    try {
      while (_items.isNotEmpty) {
        final op = {..._items.first, 'queued': true};
        try {
          await _send(op);
        } on ApiException catch (e) {
          if (e.isNetwork) break; // still offline — keep everything, try later
          debugPrint('outbox: dropping ${op['type']} (${e.code})');
        }
        _items.removeAt(0);
        await _persist();
        notifyListeners();
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _persist() async => (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_items));
}
