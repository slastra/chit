import 'package:chit/core/notify_plan.dart';
import 'package:chit/core/protocol.dart';
import 'package:chit/data/replica.dart';
import 'package:flutter_test/flutter_test.dart';

Library lib(Map<String, ({String reminder, bool done, String trashed})> notes) => Library(
  notes: [
    for (final MapEntry(:key, :value) in notes.entries)
      Note({'id': key, 'kind': 'text', 'title': 'Note $key', 'body': 'about $key', 'trashed': value.trashed}),
  ],
  items: const {},
  members: const {},
  states: {
    for (final MapEntry(:key, :value) in notes.entries)
      key: NoteState({'note': key, 'reminder': value.reminder, 'reminder_done': value.done}),
  },
  attachments: const {},
);

void main() {
  final now = DateTime.utc(2026, 11, 26, 12);
  String at(Duration d) => now.add(d).toIso8601String();

  test('a future reminder schedules once, and again when its text changes', () {
    final l = lib({'a': (reminder: at(const Duration(hours: 2)), done: false, trashed: '')});
    final first = planReminders(l, {}, now);
    expect(first.schedule.map((r) => r.note), ['a']);
    expect(first.schedule.single.title, 'Note a');
    expect(planReminders(l, first.next, now).schedule, isEmpty);
    final edited = {'a': (reminder: first.next['a']!.reminder, sig: 'older text')};
    expect(planReminders(l, edited, now).schedule.map((r) => r.note), ['a']);
  });

  test('missed: shown under 12 hours, quiet over; fired ones stay quiet', () {
    final l = lib({
      'recent': (reminder: at(const Duration(hours: -3)), done: false, trashed: ''),
      'old': (reminder: at(const Duration(hours: -13)), done: false, trashed: ''),
    });
    final p = planReminders(l, {}, now);
    expect(p.show.map((r) => r.note), ['recent']);
    expect(p.next.keys, containsAll(['recent', 'old']));
    // scheduled before (its alarm fired on time): nothing more to do
    final again = planReminders(l, p.next, now);
    expect(again.show, isEmpty);
    expect(again.cancel, isEmpty);
  });

  test('done elsewhere, cleared, trashed or gone: taken back', () {
    final r = at(const Duration(hours: 1));
    final prev = {
      for (final id in ['done', 'cleared', 'trashed', 'gone']) id: (reminder: r, sig: ''),
    };
    final l = lib({
      'done': (reminder: r, done: true, trashed: ''),
      'cleared': (reminder: '', done: false, trashed: ''),
      'trashed': (reminder: r, done: false, trashed: '2026-11-26'),
    });
    final p = planReminders(l, prev, now);
    expect(p.cancel, unorderedEquals(['done', 'cleared', 'trashed', 'gone']));
    expect(p.next, isEmpty);
  });

  test('snoozed: the shown one goes, the new time schedules', () {
    final prev = {'a': (reminder: at(const Duration(minutes: -1)), sig: 'Note a\nabout a')};
    final l = lib({'a': (reminder: at(const Duration(minutes: 10)), done: false, trashed: '')});
    final p = planReminders(l, prev, now);
    expect(p.cancel, ['a']);
    expect(p.schedule.map((r) => r.note), ['a']);
  });

  test('activity groups per person and note, folding past four lines', () {
    final groups = groupActivity(
      [
        (by: 'ang', note: 'g', sentence: 'one'),
        (by: 'leo', note: 'g', sentence: 'x'),
        (by: 'ang', note: 'g', sentence: 'two'),
      ],
      pending: {
        'ang/g': ['zero'],
      },
    );
    expect(groups.map((g) => g.by), ['ang', 'leo']);
    expect(groups[0].lines, ['zero', 'one', 'two']);
    expect(groups[1].lines, ['x']);
    expect(activityBody(['1', '2', '3', '4']), '1\n2\n3\n4');
    expect(activityBody(['1', '2', '3', '4', '5']), '1\n2\n3\nand 2 more');
  });

  test('notification ids are stable and positive', () {
    expect(notificationId('r:abc'), notificationId('r:abc'));
    expect(notificationId('r:abc'), isNot(notificationId('a:x/abc')));
    expect(notificationId('r:abc'), greaterThanOrEqualTo(0));
  });
}
