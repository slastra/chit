/// What the phone's notifications should be, decided without touching the
/// platform: which reminders to schedule, show now or take back, and how
/// other people's edits group into one notification per person and note.
library;

import '../data/replica.dart' show Library;
import 'describe.dart' show feedTitle;
import 'reminders.dart';

/// A reminder ready to be scheduled or shown.
typedef DueReminder = ({String note, DateTime at, String title, String body});

/// What this device last did about each note's reminder, by note: the
/// reminder time it acted on, and a signature of the text it showed.
typedef ReminderLedger = Map<String, ({String reminder, String sig})>;

/// A missed reminder still worth showing late (the phone was off, or
/// asleep with the app never run).
const missedWindow = Duration(hours: 12);

/// The reminder's notification text: the note's title, and its text or its
/// open items.
({String title, String body}) reminderText(Library lib, String noteId) {
  final note = lib.note(noteId)!;
  final items = lib.items[noteId] ?? const [];
  final body = note.isList
      ? items.where((i) => !i.checked).map((i) => i.text.trim()).where((t) => t.isNotEmpty).join(', ')
      : note.body.trim();
  final title = note.title.isNotEmpty ? note.title : feedTitle(note);
  return (title: title, body: body.length > 300 ? '${body.substring(0, 300)}…' : body);
}

/// Compares the reminders [lib] wants with what this device already did
/// ([prev]): new or changed ones to schedule, ones whose time passed
/// unseen to show now (within [missedWindow]), and ones to take back
/// (done, cleared, trashed, gone, or moved to another time). [next] is the
/// ledger to keep.
({List<DueReminder> schedule, List<DueReminder> show, List<String> cancel, ReminderLedger next}) planReminders(
  Library lib,
  ReminderLedger prev,
  DateTime now,
) {
  final schedule = <DueReminder>[];
  final show = <DueReminder>[];
  final cancel = <String>[];
  final next = <String, ({String reminder, String sig})>{};
  for (final note in lib.notes) {
    if (note.trashed.isNotEmpty) continue;
    final st = lib.states[note.id];
    if (st == null || st.reminderDone) continue;
    final at = reminderTime(st.reminder);
    if (at == null) continue;
    final text = reminderText(lib, note.id);
    final sig = '${text.title}\n${text.body}';
    final due = (note: note.id, at: at, title: text.title, body: text.body);
    final was = prev[note.id];
    if (was != null && was.reminder != st.reminder) cancel.add(note.id); // moved: the old one goes
    if (at.isAfter(now)) {
      if (was == null || was.reminder != st.reminder || was.sig != sig) schedule.add(due);
      next[note.id] = (reminder: st.reminder, sig: sig);
    } else if (was != null && was.reminder == st.reminder) {
      next[note.id] = was; // scheduled here before: its alarm has fired
    } else {
      if (now.difference(at) < missedWindow) show.add(due);
      next[note.id] = (reminder: st.reminder, sig: sig);
    }
  }
  for (final id in prev.keys) {
    if (!next.containsKey(id)) cancel.add(id);
  }
  return (schedule: schedule, show: show, cancel: cancel, next: next);
}

/// One person's edits to one note, as one notification.
typedef ActivityGroup = ({String by, String note, List<String> lines});

/// Groups sentences per (person, note), in the order they first appear,
/// adding to [pending] (groups not yet seen, from earlier runs).
List<ActivityGroup> groupActivity(
  Iterable<({String by, String note, String sentence})> events, {
  Map<String, List<String>> pending = const {},
}) {
  final groups = <String, ActivityGroup>{};
  for (final e in events) {
    final key = '${e.by}/${e.note}';
    final g = groups[key] ??= (by: e.by, note: e.note, lines: [...?pending[key]]);
    g.lines.add(e.sentence);
  }
  return groups.values.toList();
}

/// A group's lines as a notification body: four at most, the rest folded
/// into "and N more" (as chitd's toasts do).
String activityBody(List<String> lines) =>
    (lines.length > 4 ? [...lines.take(3), 'and ${lines.length - 3} more'] : lines).join('\n');

/// A stable notification id: FNV-1a of [key], 31 bits.
int notificationId(String key) {
  var h = 0x811c9dc5;
  for (final c in key.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}
