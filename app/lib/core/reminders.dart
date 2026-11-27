/// Reminder times: the quick presets, the wire format, and short labels.
library;

import 'package:intl/intl.dart';

/// A reminder time as the wire carries it: UTC, RFC 3339, to the second
/// (as `chit remind` writes it).
String reminderWire(DateTime at) {
  final u = at.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

/// A stored reminder as a local time (PocketBase writes "2026-11-27
/// 15:00:00.000Z"; RFC 3339 reads too). Null when empty or unreadable.
DateTime? reminderTime(String s) => s.isEmpty ? null : DateTime.tryParse(s.replaceFirst(' ', 'T'))?.toLocal();

/// A reminder as a chip can show it, short enough for a phone-width card:
/// "Today 9 AM", "Fri 9:30 AM" within the week, then "Dec 4 9 AM".
String reminderLabel(DateTime d, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(today.year, today.month, today.day)).inDays;
  final day = days == 0
      ? 'Today'
      : days > 0 && days < 7
      ? DateFormat.E().format(d)
      : DateFormat.MMMd().format(d);
  final time = d.minute == 0 ? DateFormat.j().format(d) : DateFormat.jm().format(d);
  return '$day $time';
}

/// The quick choices, as of [now] (local): later today (only before
/// five), tomorrow morning, and next week (Monday morning).
List<({String label, DateTime at})> reminderPresets(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  // the coming Monday; a week on if today is Monday
  final toMonday = (DateTime.monday - now.weekday) % 7;
  final monday = today.add(Duration(days: toMonday == 0 ? 7 : toMonday));
  return [
    if (now.hour < 17) (label: 'Later today', at: today.add(const Duration(hours: 18))),
    (label: 'Tomorrow morning', at: tomorrow.add(const Duration(hours: 8))),
    (label: 'Next week', at: monday.add(const Duration(hours: 8))),
  ];
}
