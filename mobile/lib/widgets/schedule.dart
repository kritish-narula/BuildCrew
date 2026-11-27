import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'common.dart' show timeAgo;

/// Start-time slots a customer can pick instead of an exact time: (start hour, end hour), local time.
const slotHours = <String, (int, int)>{'morning': (8, 11), 'afternoon': (12, 15), 'evening': (16, 19)};
const timeSlots = ['morning', 'afternoon', 'evening'];

String slotLabel(L l, String slot) => switch (slot) {
      'morning' => l.slotMorning,
      'afternoon' => l.slotAfternoon,
      'evening' => l.slotEvening,
      _ => l.slotExact,
    };

/// A slot can still be booked until it ends (so the 8-11 slot is open at 10:30), an exact time until it has passed.
bool slotStillOpen(String slot, DateTime day, DateTime now) {
  final end = slotHours[slot]!.$2;
  return DateTime(day.year, day.month, day.day, end).isAfter(now);
}

/// "Today" / "Tomorrow" / "Sat 30 Nov" (the year is added only when it is not this year).
String dayText(L l, DateTime at) {
  final now = DateTime.now();
  final diff = DateTime(at.year, at.month, at.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (diff == 0) return l.today;
  if (diff == 1) return l.tomorrow;
  return DateFormat(at.year == now.year ? 'EEE d MMM' : 'EEE d MMM yyyy').format(at);
}

/// "9 AM" / "9:30 AM": the minutes only when there are some.
String clockText(DateTime at) => DateFormat(at.minute == 0 ? 'h a' : 'h:mm a').format(at);

/// "Today, 9 AM" / "Tomorrow, Morning 8-11" / "Sat 30 Nov, 4:30 PM". Null when the job has no schedule.
String? scheduleText(L l, String? iso, String? slot) {
  if (iso == null) return null;
  final at = DateTime.tryParse(iso)?.toLocal();
  if (at == null) return null;
  final time = (slot != null && slotHours.containsKey(slot)) ? slotLabel(l, slot) : clockText(at);
  return '${dayText(l, at)}, $time';
}

/// Any date the app stores (a date like 2026-11-30 or a full timestamp) as a human day: "Sat 30 Nov". Null if unreadable.
String? humanDate(L l, String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final at = DateTime.tryParse(iso)?.toLocal();
  return at == null ? null : dayText(l, at);
}

/// A timestamp as "Today, 9 AM" (job times, "paid on", "will be released on").
String? humanDateTime(L l, String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final at = DateTime.tryParse(iso)?.toLocal();
  return at == null ? null : '${dayText(l, at)}, ${clockText(at)}';
}

/// "5 min ago" / "2 hr ago" / "yesterday" for messages and quotes. Null if unreadable.
String? agoText(L l, String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final at = DateTime.tryParse(iso)?.toLocal();
  return at == null ? null : timeAgo(l, at);
}

/// One line with a clock icon: used on job cards for workers and customers. Renders nothing without a schedule.
class ScheduleLine extends StatelessWidget {
  const ScheduleLine({super.key, required this.iso, required this.slot, this.color = BC.inkSoft});
  final String? iso, slot;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final text = scheduleText(L.of(context), iso, slot);
    if (text == null) return const SizedBox.shrink();
    return Row(children: [
      Icon(Icons.event_available_rounded, size: 16, color: color),
      const SizedBox(width: 4),
      Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color))),
    ]);
  }
}

/// "3 masons needed" (English adds the plural s; other languages use the trade name as is).
String tradeCount(L l, String tradeName, int n) {
  final plural = l.localeName.startsWith('en') && n > 1 ? '${tradeName}s' : tradeName;
  return '$n $plural';
}
