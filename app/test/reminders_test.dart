import 'package:chit/core/reminders.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the wire format is UTC to the second', () {
    expect(reminderWire(DateTime.utc(2026, 11, 27, 15, 4, 5, 678)), '2026-11-27T15:04:05Z');
    expect(reminderTime('2026-11-27 15:00:00.000Z'), DateTime.utc(2026, 11, 27, 15).toLocal());
    expect(reminderTime(''), isNull);
  });

  test('presets: later today only before five; next week is a Monday', () {
    final morning = reminderPresets(DateTime(2026, 11, 26, 10)); // a Thursday
    expect(morning.map((p) => p.label), ['Later today', 'Tomorrow morning', 'Next week']);
    expect(morning[0].at, DateTime(2026, 11, 26, 18));
    expect(morning[1].at, DateTime(2026, 11, 27, 8));
    expect(morning[2].at, DateTime(2026, 11, 30, 8));
    final evening = reminderPresets(DateTime(2026, 11, 26, 17, 30));
    expect(evening.map((p) => p.label), ['Tomorrow morning', 'Next week']);
    // on a Monday, next week is the Monday after
    expect(reminderPresets(DateTime(2026, 11, 30, 9)).last.at, DateTime(2026, 12, 7, 8));
  });

  test('labels stay short', () {
    final now = DateTime(2026, 11, 26, 10);
    // ICU puts a narrow no-break space before AM/PM
    String label(DateTime d) => reminderLabel(d, now: now).replaceAll('\u202f', ' ');
    expect(label(DateTime(2026, 11, 26, 18)), 'Today 6 PM');
    expect(label(DateTime(2026, 11, 27, 8, 30)), 'Fri 8:30 AM');
    expect(label(DateTime(2026, 12, 10, 9)), 'Dec 10 9 AM');
  });
}
