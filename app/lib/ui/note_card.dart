import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'note_colors.dart';

/// A note on the grid: title, the start of the body or the open items, and
/// small marks for pinned, reminder, shared and files. A colored note draws
/// in its color's tonal container. Lists check off right on the card.
class NoteCard extends ConsumerWidget {
  const NoteCard({super.key, required this.note, required this.library});

  final Note note;
  final Library library;

  static const _itemsShown = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = noteScheme(note.color, theme.brightness);
    final fill = scheme?.primaryContainer ?? theme.colorScheme.surfaceContainerHigh;
    final ink = scheme?.onPrimaryContainer ?? theme.colorScheme.onSurface;
    final faint = ink.withValues(alpha: 0.7);
    final text = theme.textTheme;

    final state = library.stateOf(note.id);
    final items = library.items[note.id] ?? const <Item>[];
    final open = items.where((i) => !i.checked).toList();
    final done = items.length - open.length;
    final files = library.attachments[note.id] ?? const <Attachment>[];
    final shared = (library.members[note.id]?.isNotEmpty ?? false) || note.owner != ref.watch(sessionProvider).value?.user.id;
    final reminder = state.reminderDone ? '' : state.reminder;

    return Card.filled(
      color: fill,
      child: InkWell(
        onTap: () => context.push('/note/${note.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              if (note.title.isNotEmpty || (note.body.isEmpty && items.isEmpty))
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        note.label.isEmpty ? 'Empty note' : note.label,
                        style: text.titleMedium?.copyWith(color: ink, fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (state.pinned) Icon(Icons.push_pin, size: 16, color: faint),
                  ],
                ),
              if (!note.isList && note.body.isNotEmpty)
                Text(note.body, style: text.bodyMedium?.copyWith(color: ink), maxLines: 10, overflow: TextOverflow.ellipsis),
              if (note.isList)
                for (final it in open.take(_itemsShown))
                  _ItemLine(item: it, ink: ink, onCheck: () => _check(ref, it)),
              if (note.isList && (open.length > _itemsShown || done > 0))
                Text(
                  [if (open.length > _itemsShown) '${open.length - _itemsShown} more', if (done > 0) '$done checked'].join(' · '),
                  style: text.labelMedium?.copyWith(color: faint),
                ),
              if (reminder.isNotEmpty || shared || files.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (reminder.isNotEmpty) _Mark(icon: Icons.alarm, label: _when(context, reminder), ink: faint),
                    if (shared) _Mark(icon: Icons.group_outlined, ink: faint),
                    if (files.isNotEmpty) _Mark(icon: Icons.attach_file, label: '${files.length}', ink: faint),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _check(WidgetRef ref, Item it) {
    final engine = ref.read(engineProvider);
    if (engine == null) return;
    engine.edit([engine.op(Collections.items, it.id, 'checked', true)]);
  }

  static String _when(BuildContext context, String s) {
    final d = DateTime.tryParse(s.replaceFirst(' ', 'T'))?.toLocal();
    if (d == null) return '';
    final day = DateUtils.isSameDay(d, DateTime.now()) ? 'Today' : MaterialLocalizations.of(context).formatShortMonthDay(d);
    return '$day ${TimeOfDay.fromDateTime(d).format(context)}';
  }
}

class _ItemLine extends StatelessWidget {
  const _ItemLine({required this.item, required this.ink, required this.onCheck});
  final Item item;
  final Color ink;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // its own tap target, so checking does not open the note
      InkResponse(
        onTap: onCheck,
        radius: 16,
        child: Padding(padding: const EdgeInsets.only(right: 8, top: 1), child: Icon(Icons.check_box_outline_blank, size: 18, color: ink)),
      ),
      Expanded(
        child: Text(item.text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ink), maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

class _Mark extends StatelessWidget {
  const _Mark({required this.icon, this.label = '', required this.ink});
  final IconData icon;
  final String label;
  final Color ink;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Icon(icon, size: 14, color: ink),
      if (label.isNotEmpty) Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: ink)),
    ],
  );
}
