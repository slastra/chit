import 'dart:async';

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../core/reminders.dart';
import 'home_page.dart' show isExpanded;

/// Asks for a reminder date and time with Material's pickers. Null when
/// cancelled.
Future<DateTime?> pickReminder(BuildContext context, {DateTime? initial}) async {
  final now = DateTime.now();
  final start = initial != null && initial.isAfter(now) ? initial : now.add(const Duration(hours: 1));
  final day = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 365 * 5)),
    helpText: 'Remind me on',
  );
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: initial != null ? TimeOfDay.fromDateTime(initial) : const TimeOfDay(hour: 8, minute: 0),
    helpText: 'Remind me at',
  );
  if (time == null) return null;
  return DateTime(day.year, day.month, day.day, time.hour, time.minute);
}

/// The ways to set a reminder: Keep's presets, a date and time of your
/// own, and removing one that is set.
List<({String label, String detail, IconData icon, FutureOr<void> Function(BuildContext) run})> _choices({
  required DateTime? current,
  required ValueChanged<DateTime> onSet,
  required VoidCallback onClear,
}) => [
  for (final p in reminderPresets(DateTime.now()))
    (label: p.label, detail: DateFormat.E().add_j().format(p.at), icon: Icons.schedule, run: (_) => onSet(p.at)),
  (
    label: 'Pick a date and time',
    detail: '',
    icon: Icons.event_outlined,
    run: (context) async {
      final at = await pickReminder(context, initial: current);
      if (at != null) onSet(at);
    },
  ),
  if (current != null) (label: 'Remove reminder', detail: '', icon: Icons.alarm_off, run: (_) => onClear()),
];

/// The note's reminder button: a menu beside it on expanded windows, a
/// bottom sheet on compact ones. Filled while a reminder is set.
class ReminderButton extends StatelessWidget {
  const ReminderButton({super.key, required this.current, required this.onSet, required this.onClear});
  final DateTime? current;
  final ValueChanged<DateTime> onSet;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tooltip = current == null ? 'Remind me' : 'Reminder: ${reminderLabel(current!)}';
    final icon = Icon(current == null ? Icons.add_alarm_outlined : Icons.alarm);
    final choices = _choices(current: current, onSet: onSet, onClear: onClear);
    if (isExpanded(context)) {
      return MenuAnchor(
        builder: (context, menu, _) => IconButton(
          tooltip: tooltip,
          isSelected: current != null,
          icon: icon,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
        menuChildren: [
          for (final c in choices)
            MenuItemButton(
              leadingIcon: Icon(c.icon),
              trailingIcon: c.detail.isEmpty ? null : Text(c.detail),
              onPressed: () => c.run(context),
              child: Text(c.label),
            ),
        ],
      );
    }
    return IconButton(
      tooltip: tooltip,
      isSelected: current != null,
      icon: icon,
      onPressed: () => showReminderSheet(context, current: current, onSet: onSet, onClear: onClear),
    );
  }
}

/// The reminder choices as a bottom sheet (compact windows, and the chip).
Future<void> showReminderSheet(
  BuildContext context, {
  required DateTime? current,
  required ValueChanged<DateTime> onSet,
  required VoidCallback onClear,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (sheet) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('Remind me', style: Theme.of(sheet).textTheme.titleMedium),
        ),
        for (final c in _choices(current: current, onSet: onSet, onClear: onClear))
          ListTile(
            leading: Icon(c.icon),
            title: Text(c.label),
            trailing: c.detail.isEmpty ? null : Text(c.detail),
            onTap: () {
              Navigator.pop(sheet);
              c.run(context);
            },
          ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);
