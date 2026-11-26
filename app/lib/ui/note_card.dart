import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'note_colors.dart';

/// A note on the grid: title, the start of the body or the open items, and
/// small marks for pinned, reminder, shared and files. A plain note is an
/// outlined card; a colored one fills with its color's tonal container (as
/// Keep draws them). Lists check off right on the card.
class NoteCard extends ConsumerWidget {
  const NoteCard({super.key, required this.note, required this.library});

  final Note note;
  final Library library;

  static const _itemsShown = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = noteScheme(note.color, theme.brightness);
    final ink = scheme?.onPrimaryContainer ?? theme.colorScheme.onSurface;
    final faint = ink.withValues(alpha: 0.7);
    final text = theme.textTheme;

    final state = library.stateOf(note.id);
    final items = library.items[note.id] ?? const <Item>[];
    final open = items.where((i) => !i.checked).toList();
    final done = items.length - open.length;
    final files = library.attachments[note.id] ?? const <Attachment>[];
    final shared =
        (library.members[note.id]?.isNotEmpty ?? false) || note.owner != ref.watch(sessionProvider).value?.user.id;
    final reminder = state.reminderDone ? '' : state.reminder;

    final more = open.length - _itemsShown;
    final hasFooter = reminder.isNotEmpty || shared || files.isNotEmpty || (note.isList && (more > 0 || done > 0));
    final rule = scheme?.onPrimaryContainer.withValues(alpha: 0.16) ?? theme.colorScheme.outlineVariant;

    final body = InkWell(
      onTap: () => context.push('/note/${note.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // content: title, then the text or the open items
          Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, hasFooter ? 10 : 14),
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
                  Text(
                    note.body,
                    style: text.bodyMedium?.copyWith(color: ink),
                    maxLines: 10,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (note.isList)
                  for (final it in open.take(_itemsShown))
                    _ItemLine(item: it, ink: ink, onCheck: () => _check(ref, it)),
              ],
            ),
          ),
          // footer: the note's specifics, below a hairline (Material's card
          // anatomy: a separate bottom region for metadata and actions)
          if (hasFooter) ...[
            Divider(height: 1, thickness: 1, color: rule),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (reminder.isNotEmpty) _ReminderChip(label: _when(context, reminder), scheme: scheme),
                  if (note.isList && more > 0) _Mark(label: '$more more', ink: faint),
                  if (note.isList && done > 0) _Mark(icon: Icons.check, label: '$done checked', ink: faint),
                  if (files.isNotEmpty) _Mark(icon: Icons.attach_file, label: '${files.length}', ink: faint),
                  if (shared) _Mark(icon: Icons.group_outlined, ink: faint, tooltip: 'Shared'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    // The theme's card shape (the desktop's corner radius) has no border, and
    // would erase the outlined card's; put the hairline back on it.
    final corners = theme.cardTheme.shape is RoundedRectangleBorder
        ? (theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius
        : const BorderRadius.all(Radius.circular(12));
    return scheme == null
        ? Card.outlined(
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: corners,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: body,
          )
        : Card.filled(color: scheme.primaryContainer, child: body);
  }

  void _check(WidgetRef ref, Item it) {
    final engine = ref.read(engineProvider);
    if (engine == null) return;
    engine.edit([engine.op(Collections.items, it.id, 'checked', true)]);
  }

  static String _when(BuildContext context, String s) {
    final d = DateTime.tryParse(s.replaceFirst(' ', 'T'))?.toLocal();
    if (d == null) return '';
    final day = DateUtils.isSameDay(d, DateTime.now())
        ? 'Today'
        : MaterialLocalizations.of(context).formatShortMonthDay(d);
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
      // its own tap target (taller than the glyph, so it is easy to hit),
      // so checking does not open the note
      Semantics(
        button: true,
        label: 'Check ${item.text}',
        child: InkResponse(
          onTap: onCheck,
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 10, 2),
            child: Icon(Icons.check_box_outline_blank, size: 18, color: ink),
          ),
        ),
      ),
      Expanded(
        child: Text(
          item.text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

class _Mark extends StatelessWidget {
  const _Mark({this.icon, this.label = '', required this.ink, this.tooltip});
  final IconData? icon;
  final String label;
  final Color ink;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final mark = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (icon != null) Icon(icon, size: 14, color: ink),
        if (label.isNotEmpty) Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: ink)),
      ],
    );
    return tooltip == null ? mark : Tooltip(message: tooltip, child: mark);
  }
}

/// A reminder, as a small tonal chip (Material's assist-chip look, sized for
/// a card): it is state on the note, not just a caption.
class _ReminderChip extends StatelessWidget {
  const _ReminderChip({required this.label, required this.scheme});
  final String label;
  final ColorScheme? scheme;

  @override
  Widget build(BuildContext context) {
    final cs = scheme ?? Theme.of(context).colorScheme;
    final bg = scheme == null ? cs.secondaryContainer : cs.onPrimaryContainer.withValues(alpha: 0.12);
    final fg = scheme == null ? cs.onSecondaryContainer : cs.onPrimaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(Icons.alarm, size: 14, color: fg),
            Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}
