import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'attachments.dart';
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
    final images = files.where((a) => a.isImage).toList();
    final others = files.where((a) => !a.isImage).toList();
    // one mark per kind of file, counted when there are several
    final kinds = <MediaKind, List<Attachment>>{};
    for (final a in others) {
      (kinds[a.kind] ??= []).add(a);
    }
    final uploading = others.where((a) => a.pending).firstOrNull;
    final shared =
        (library.members[note.id]?.isNotEmpty ?? false) || note.owner != ref.watch(sessionProvider).value?.user.id;
    final reminder = state.reminderDone ? '' : state.reminder;

    final more = open.length - _itemsShown;
    final hasFooter = reminder.isNotEmpty || shared || others.isNotEmpty || (note.isList && (more > 0 || done > 0));
    final rule = scheme?.onPrimaryContainer.withValues(alpha: 0.16) ?? theme.colorScheme.outlineVariant;

    final body = InkWell(
      onTap: () => context.push('/note/${note.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // images across the top, as Keep shows them
          if (images.isNotEmpty) _CardImages(images: images),
          // content: title, then the text or the open items
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, hasFooter ? 12 : 16),
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
                          style: text.titleMedium?.copyWith(color: ink),
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
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (reminder.isNotEmpty)
                    _ReminderChip(
                      label: _when(context, reminder),
                      scheme: scheme,
                      onPressed: () => context.push('/note/${note.id}'),
                    ),
                  if (note.isList && more > 0) _Mark(label: '$more more', ink: faint),
                  if (note.isList && done > 0) _Mark(icon: Icons.check, label: '$done checked', ink: faint),
                  for (final MapEntry(key: kind, value: list) in kinds.entries)
                    _Mark(
                      icon: kindIcon(list.first),
                      label: list.length > 1 ? '${list.length}' : '',
                      ink: faint,
                      tooltip: switch (kind) {
                        MediaKind.pdf => list.length > 1 ? '${list.length} PDFs' : 'PDF',
                        MediaKind.video => list.length > 1 ? '${list.length} videos' : 'Video',
                        MediaKind.audio => list.length > 1 ? '${list.length} recordings' : 'Recording',
                        _ => list.length > 1 ? '${list.length} files' : 'File',
                      },
                    ),
                  if (uploading != null) UploadMark(uploading, size: 14),
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

  /// A reminder as a chip can show it on a phone-width card: "Today 9 AM",
  /// "Fri 9:30 AM" within the week, then "Dec 4 9 AM".
  static String _when(BuildContext context, String s) {
    final d = DateTime.tryParse(s.replaceFirst(' ', 'T'))?.toLocal();
    if (d == null) return '';
    final now = DateTime.now();
    final days = DateUtils.dateOnly(d).difference(DateUtils.dateOnly(now)).inDays;
    final day = days == 0
        ? 'Today'
        : days > 0 && days < 7
        ? DateFormat.E().format(d)
        : DateFormat.MMMd().format(d);
    final time = d.minute == 0 ? DateFormat.j().format(d) : DateFormat.jm().format(d);
    return '$day $time';
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

/// A reminder, as Material's assist chip (Flutter's ActionChip: 32dp, small
/// corners, an 18dp icon, a hairline outline): it opens the note, where the
/// reminder is set. On a colored note it takes that color's ink.
class _ReminderChip extends StatelessWidget {
  const _ReminderChip({required this.label, required this.scheme, required this.onPressed});
  final String label;
  final ColorScheme? scheme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = scheme;
    return ActionChip(
      avatar: Icon(Icons.alarm, color: cs?.onPrimaryContainer),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      labelStyle: cs == null ? null : TextStyle(color: cs.onPrimaryContainer),
      side: cs == null ? null : BorderSide(color: cs.onPrimaryContainer.withValues(alpha: 0.3)),
      onPressed: onPressed,
    );
  }
}

/// A card's images: one at its own shape (up to 240dp tall), or up to three
/// squares in a row, the last counting any more.
class _CardImages extends StatelessWidget {
  const _CardImages({required this.images});
  final List<Attachment> images;

  @override
  Widget build(BuildContext context) {
    if (images.length == 1) {
      final a = images.first;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: Stack(
          children: [
            AttachmentImage(a, thumb: '1080x0', width: double.infinity, placeholderHeight: 140),
            Positioned(right: 8, bottom: 8, child: UploadMark(a, size: 16, onImage: true)),
          ],
        ),
      );
    }
    final shown = images.take(3).toList();
    final extra = images.length - shown.length;
    return Row(
      spacing: 2,
      children: [
        for (final (i, a) in shown.indexed)
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AttachmentImage(a, thumb: '320x320'),
                  if (i == shown.length - 1 && extra > 0)
                    ColoredBox(
                      color: const Color(0x80000000),
                      child: Center(
                        child: Text(
                          '+$extra',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  Positioned(right: 4, bottom: 4, child: UploadMark(a, size: 14, onImage: true)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
