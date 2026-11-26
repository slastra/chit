import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../core/reminders.dart';
import '../core/roles.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'check_motion.dart';
import 'note_colors.dart';
import 'people.dart';

/// A note on the grid: title, the start of the body or the open items, and
/// small marks for pinned, reminder, shared and files. A plain note is an
/// outlined card; a colored one fills with its color's tonal container (as
/// Keep draws them). Lists check off right on the card.
class NoteCard extends ConsumerStatefulWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.library,
    this.onMove,
    this.onMoveTop,
    this.selected = false,
    this.selecting = false,
    this.onSelect,
    this.longPressSelects = false,
  });

  final Note note;
  final Library library;

  /// Moves the note earlier (-1) or later (+1) on the board, and to the
  /// top: Alt+arrows on a focused card, and screen readers' actions. Null
  /// where the board cannot be arranged (archive, trash, a search).
  final void Function(int by)? onMove;
  final VoidCallback? onMoveTop;

  /// Selection on the board: whether this card is selected, whether any
  /// is (a tap then selects rather than opens), and how to toggle it.
  /// Ctrl- or Shift-click toggles too, and the check at the card's top end
  /// (shown on hover, and on every card while selecting).
  final bool selected;
  final bool selecting;
  final VoidCallback? onSelect;

  /// A long press selects (where it doesn't lift the card for a drag).
  final bool longPressSelects;

  @override
  ConsumerState<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends ConsumerState<NoteCard> {
  static const _itemsShown = 8;

  /// Whether the list was all checked at the last build, to fold the other
  /// items in at the moment the last one is checked off.
  bool? _wasAllDone;

  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final library = widget.library;
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
    final me = ref.watch(sessionProvider).value?.user.id ?? '';
    final shared = (library.members[note.id]?.isNotEmpty ?? false) || note.owner != me;
    final reminder = state.reminderDone ? '' : state.reminder;

    // the "Empty note" placeholder is for notes with nothing at all: a
    // note of only images or files shows just those
    final showTitle = note.title.isNotEmpty || (note.body.isEmpty && items.isEmpty && files.isEmpty);
    final hasText = showTitle || (!note.isList && note.body.isNotEmpty) || (note.isList && items.isNotEmpty);
    // every item checked: the card shows the whole list, checked off
    final allDone = note.isList && items.isNotEmpty && open.isEmpty;
    final revealing = _wasAllDone == false && allDone;
    _wasAllDone = allDone;
    final lines = allDone ? items.take(_itemsShown).toList() : open.take(_itemsShown).toList();
    final more = (allDone ? items.length : open.length) - _itemsShown;
    final showDone = note.isList && done > 0 && !allDone; // the list says it when all are done
    final labels = library.labelsOf(note.id);
    final hasFooter =
        reminder.isNotEmpty ||
        labels.isNotEmpty ||
        shared ||
        others.isNotEmpty ||
        (note.isList && more > 0) ||
        showDone;
    final rule = scheme?.onPrimaryContainer.withValues(alpha: 0.16) ?? theme.colorScheme.outlineVariant;

    final select = widget.onSelect;
    final body = InkWell(
      onTap: () {
        final keys = HardwareKeyboard.instance;
        if (select != null &&
            (widget.selecting || keys.isControlPressed || keys.isShiftPressed || keys.isMetaPressed)) {
          select();
        } else {
          context.push('/note/${note.id}');
        }
      },
      onLongPress: widget.longPressSelects ? select : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // images across the top, as Keep shows them
          if (images.isNotEmpty) _CardImages(images: images),
          // content: title, then the text or the open items
          if (hasText)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, hasFooter ? 12 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showTitle)
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
                    Padding(
                      padding: EdgeInsets.only(top: showTitle ? 6 : 0),
                      child: Text(
                        note.body,
                        style: text.bodyMedium?.copyWith(color: ink),
                        maxLines: 10,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // each line carries its own gap above, so a line folding
                  // away takes its gap with it
                  if (note.isList)
                    for (final (i, it) in lines.indexed)
                      _ItemLine(
                        key: ValueKey(it.id),
                        item: it,
                        ink: ink,
                        topGap: showTitle || i > 0 ? 6 : 0,
                        // the last open item stays put: the list comes back
                        // whole, checked, around it
                        last: !allDone && open.length == 1,
                        enter: revealing,
                        // a viewer's card shows the list but checks nothing
                        onCheck: canEdit(roleOf(note, library.members[note.id] ?? const <Member>[], me))
                            ? () => _check(ref, it)
                            : null,
                      ),
                ],
              ),
            ),
          // footer: the note's specifics, below a hairline (Material's card
          // anatomy: a separate bottom region for metadata and actions)
          AnimatedSize(
            duration: Durations.medium2,
            curve: Easing.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: !hasFooter
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(height: 1, thickness: 1, color: rule),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (reminder.isNotEmpty)
                              _Mark(
                                icon: Icons.alarm,
                                label: reminderLabel(reminderTime(reminder)!),
                                ink: faint,
                                tooltip: 'Reminder',
                              ),
                            // two labels at most; the rest as a count
                            for (final l in labels.take(2)) _Mark(icon: Icons.label_outline, label: l.name, ink: faint),
                            if (labels.length > 2)
                              _Mark(
                                label: '+${labels.length - 2}',
                                ink: faint,
                                tooltip: labels.skip(2).map((l) => l.name).join(', '),
                              ),
                            if (note.isList && more > 0) _Mark(label: '$more more', ink: faint),
                            if (showDone) _Mark(icon: Icons.check, label: '$done checked', ink: faint),
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
                            if (shared)
                              _Sharers(
                                ids: [
                                  if (note.owner != me) note.owner,
                                  for (final m in library.members[note.id] ?? const <Member>[])
                                    if (m.user != me) m.user,
                                ],
                                ring: scheme?.primaryContainer ?? theme.colorScheme.surface,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
    // The theme's card shape (the desktop's corner radius) has no border, and
    // would erase the outlined card's; put the hairline back on it.
    final corners = theme.cardTheme.shape is RoundedRectangleBorder
        ? (theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius
        : const BorderRadius.all(Radius.circular(12));
    // selected: a 2dp primary outline and a filled check at the top end (a
    // checked card, as Material's checkable card draws it)
    final selected = widget.selected;
    final selectedSide = BorderSide(color: theme.colorScheme.primary, width: 2);
    final plain = scheme == null
        ? Card.outlined(
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: corners,
              side: selected ? selectedSide : BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: body,
          )
        : Card.filled(
            color: scheme.primaryContainer,
            shape: RoundedRectangleBorder(borderRadius: corners, side: selected ? selectedSide : BorderSide.none),
            child: body,
          );
    final showCheck = select != null && (selected || widget.selecting || _hover);
    final card = select == null
        ? plain
        : MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Stack(
              children: [
                plain,
                if (showCheck)
                  PositionedDirectional(
                    top: 4,
                    end: 4,
                    child: IconButton(
                      tooltip: selected ? 'Deselect note' : 'Select note',
                      isSelected: selected,
                      onPressed: select,
                      color: selected ? theme.colorScheme.primary : faint,
                      icon: const Icon(Icons.radio_button_unchecked),
                      selectedIcon: const Icon(Icons.check_circle),
                    ),
                  ),
              ],
            ),
          );
    final move = widget.onMove;
    if (move == null) return card;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => move(1),
      },
      child: Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Move earlier'): () => move(-1),
          const CustomSemanticsAction(label: 'Move later'): () => move(1),
          if (widget.onMoveTop != null) const CustomSemanticsAction(label: 'Move to top'): widget.onMoveTop!,
        },
        child: card,
      ),
    );
  }

  void _check(WidgetRef ref, Item it) {
    final engine = ref.read(engineProvider);
    if (engine == null) return;
    engine.edit([engine.op(Collections.items, it.id, 'checked', true)]);
  }
}

/// An open item on the card. Checked here, its box fills and its text is
/// struck at once; after a beat it folds away, and only then is the edit
/// sent (check_motion.dart).
class _ItemLine extends StatefulWidget {
  const _ItemLine({
    super.key,
    required this.item,
    required this.ink,
    required this.onCheck,
    this.topGap = 6,
    this.last = false,
    this.enter = false,
  });
  final Item item;
  final Color ink;
  final VoidCallback? onCheck;

  /// Space above the line, folded away with it.
  final double topGap;

  /// The list's last open item: checked, it stays where it is (the whole
  /// list returns, checked off, around it) instead of folding away.
  final bool last;

  /// Fold in on arrival (the list just became all checked).
  final bool enter;

  @override
  State<_ItemLine> createState() => _ItemLineState();
}

class _ItemLineState extends State<_ItemLine> {
  bool _checked = false;
  bool _leaving = false;
  bool _sent = false;
  Timer? _beat;

  void _send() {
    if (_sent) return;
    _sent = true;
    widget.onCheck?.call();
  }

  /// Checked already: shown struck through, and not a button.
  bool get _done => widget.item.checked;

  /// A viewer's line: shown as it is, not a button.
  bool get _locked => widget.onCheck == null;

  void _check() {
    if (_checked || _done || _locked) return;
    unawaited(HapticFeedback.selectionClick());
    if (MediaQuery.disableAnimationsOf(context)) {
      _send();
      return;
    }
    setState(() => _checked = true);
    _beat = Timer(checkBeat, () {
      if (!mounted) return;
      if (widget.last) {
        _send();
      } else {
        setState(() => _leaving = true);
      }
    });
  }

  @override
  void dispose() {
    // the card went away mid-check (scrolled off, the board changed): the
    // check still counts
    _beat?.cancel();
    if (_checked) _send();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = widget.ink;
    final checked = _checked || _done;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: checked ? ink.withValues(alpha: 0.6) : ink,
      decoration: checked ? TextDecoration.lineThrough : null,
      decorationColor: ink.withValues(alpha: 0.6),
    );
    return Fold(
      leaving: _leaving,
      enter: widget.enter,
      onGone: _send,
      child: Padding(
        padding: EdgeInsets.only(top: widget.topGap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // its own tap target (taller than the glyph, so it is easy to hit),
            // so checking does not open the note
            Semantics(
              button: !_done && !_locked,
              checked: checked,
              label: _done ? widget.item.text : 'Check ${widget.item.text}',
              child: InkResponse(
                onTap: _done || _locked ? null : _check,
                radius: 18,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 2, 10, 2),
                  child: AnimatedSwitcher(
                    duration: Durations.short3,
                    transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                    child: Icon(
                      checked ? Icons.check_box : Icons.check_box_outline_blank,
                      key: ValueKey(checked),
                      size: 18,
                      color: ink,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: Durations.short3,
                style: style ?? const TextStyle(),
                child: Text(widget.item.text, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
      ),
    );
  }
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

/// Who else is on a shared note: their faces, overlapping, three at most
/// and a count for more; their names on hover.
class _Sharers extends ConsumerWidget {
  const _Sharers({required this.ids, required this.ring});
  final List<String> ids;
  final Color ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final shown = ids.take(3).toList();
    const r = 11.0;
    return Tooltip(
      message: 'Shared with ${ids.map((i) => nameOf(people, i)).join(', ')}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: r * 2 + (shown.length - 1) * r * 1.3 + 4,
            height: r * 2 + 4,
            child: Stack(
              children: [
                for (final (i, id) in shown.indexed)
                  Positioned(
                    left: i * r * 1.3,
                    child: PersonAvatar(id: id, radius: r, ring: ring),
                  ),
              ],
            ),
          ),
          if (ids.length > 3) Text('+${ids.length - 3}', style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}
