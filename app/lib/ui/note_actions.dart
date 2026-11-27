part of 'home_page.dart';

/// What can be done to notes from the board: the selection's toolbar and a
/// card's menu share these actions. Kept apart from the board's layout;
/// the board supplies the selection and where it is.
mixin _NoteActions on ConsumerState<HomePage> {
  Set<String> get _selected;
  Shelf get _shelf;
  MenuController get _cardMenu;
  void _clearSelection();

  // ---- acting on the selection ----------------------------------------------

  /// Sends [ops] for the selection; [skipped] notes (shared ones this person
  /// may not change that way) are named in a message.
  void _apply(List<Op> ops, {int skipped = 0}) {
    final engine = ref.read(engineProvider);
    if (engine != null && ops.isNotEmpty) unawaited(engine.edit(ops));
    if (skipped > 0) {
      showMessage(
        skipped == 1 ? "1 note shared with you wasn't changed" : "$skipped notes shared with you weren't changed",
      );
    }
  }

  Op _op(String collection, String id, String field, Object? value) =>
      ref.read(engineProvider)!.op(collection, id, field, value);

  /// The selection's toolbar, afloat at the foot of the pane: close, how
  /// many, and the actions for [ids]. It has [room] to fit in: with less,
  /// the count is the number alone, then color, then the reminder move
  /// under More.
  Widget _selectionBar(Library lib, List<String> ids, List<Note> shown, double room) {
    // a button and its gap; the count; the bar's own padding
    const button = 52.0;
    final words = room >= 7 * button + 96 + 16;
    final fits = ((room - 16 - (words ? 96 : 36)) / button).floor();
    final n = ids.length;
    return FloatingToolbar(
      vibrant: true,
      children: [
        IconButton(tooltip: 'Clear selection', icon: const Icon(Icons.close), onPressed: _clearSelection),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
          child: Text(words ? '$n selected' : '$n', semanticsLabel: '$n selected'),
        ),
        ..._noteActions(lib, ids, shown, fits: fits - 1),
      ],
    );
  }

  /// What can be done to the notes [ids]: as the selection toolbar's buttons
  /// (at most [fits], the rest under More), or as a [menu]'s items (a right
  /// click on a card).
  List<Widget> _noteActions(Library lib, List<String> requested, List<Note> shown, {int fits = 0, bool menu = false}) {
    if (ref.read(engineProvider) == null) return const [];
    final me = ref.read(sessionProvider).value?.user.id ?? '';
    final notes = [for (final id in requested) ?lib.note(id)];
    if (notes.isEmpty) return const [];
    // the notes that still exist: everything below acts on these alone
    final ids = [for (final n in notes) n.id];
    final owned = [
      for (final n in notes)
        if (n.owner == me) n.id,
    ];
    final editable = [
      for (final n in notes)
        if (canEdit(roleOf(n, lib.members[n.id] ?? const <Member>[], me))) n.id,
    ];
    final n = ids.length;
    String count(String what) => n == 1 ? '1 note $what' : '$n notes $what';
    MenuItemButton item(IconData icon, String label, VoidCallback run) =>
        MenuItemButton(leadingIcon: Icon(icon), onPressed: run, child: Text(label));

    if (_shelf == Shelf.trash) {
      void restore() {
        bump();
        _apply([for (final id in owned) _op(Collections.notes, id, 'trashed', '')], skipped: n - owned.length);
        _clearSelection();
      }

      Future<void> deleteForever() async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.delete_forever_outlined),
            title: Text(n == 1 ? 'Delete this note forever?' : 'Delete $n notes forever?'),
            content: const Text('They go from every device, for everyone they are shared with.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok != true) return;
        _apply([for (final id in owned) _op(Collections.notes, id, 'deleted', true)], skipped: n - owned.length);
        _clearSelection();
      }

      if (menu) {
        return [
          item(Icons.restore_from_trash_outlined, 'Restore', restore),
          item(Icons.delete_forever_outlined, 'Delete forever', deleteForever),
        ];
      }
      return [
        IconButton(tooltip: 'Restore', icon: const Icon(Icons.restore_from_trash_outlined), onPressed: restore),
        IconButton(
          tooltip: 'Delete forever',
          icon: const Icon(Icons.delete_forever_outlined),
          onPressed: deleteForever,
        ),
      ];
    }

    final allPinned = ids.every((id) => lib.stateOf(id).pinned);
    final allArchived = ids.every((id) => lib.stateOf(id).archived);
    final colors = {for (final x in notes) x.color};
    final color = colors.length == 1 ? colors.first : '';

    void pin() {
      bump();
      _apply([for (final id in ids) _op(Collections.noteState, id, 'pinned', !allPinned)]);
      _clearSelection();
    }

    void archive() {
      bump();
      final was = {for (final id in ids) id: lib.stateOf(id).archived};
      _apply([for (final id in ids) _op(Collections.noteState, id, 'archived', !allArchived)]);
      _clearSelection();
      final engine = ref.read(engineProvider);
      showUndo(
        count(allArchived ? 'unarchived' : 'archived'),
        () => engine?.edit([
          for (final MapEntry(key: id, value: v) in was.entries) engine.op(Collections.noteState, id, 'archived', v),
        ]),
      );
    }

    void trash() {
      bump();
      final at = DateTime.now().toUtc().toIso8601String();
      _apply([for (final id in owned) _op(Collections.notes, id, 'trashed', at)], skipped: n - owned.length);
      _clearSelection();
      if (owned.isEmpty) return;
      final engine = ref.read(engineProvider);
      showUndo(
        owned.length == 1 ? 'Note moved to trash' : '${owned.length} notes moved to trash',
        () => engine?.edit([for (final id in owned) engine.op(Collections.notes, id, 'trashed', '')]),
      );
    }

    void setColor(String c) =>
        _apply([for (final id in editable) _op(Collections.notes, id, 'color', c)], skipped: n - editable.length);

    void remind(DateTime? at) => _apply([
      for (final id in ids) ...[
        _op(Collections.noteState, id, 'reminder', at == null ? '' : reminderWire(at)),
        _op(Collections.noteState, id, 'reminder_done', false),
      ],
    ]);

    void selectAll() => setState(() => _selected.addAll(shown.map((x) => x.id)));

    if (menu) {
      // one note's reminder shows as set, and can be removed
      final st = n == 1 ? lib.stateOf(ids.single) : null;
      final current = st == null || st.reminderDone ? null : reminderTime(st.reminder);
      return [
        item(allPinned ? Icons.push_pin : Icons.push_pin_outlined, allPinned ? 'Unpin' : 'Pin', pin),
        SubmenuButton(
          leadingIcon: Icon(current == null ? Icons.add_alarm_outlined : Icons.alarm),
          menuChildren: reminderMenuItems(context, current: current, onSet: remind, onClear: () => remind(null)),
          child: const Text('Remind me'),
        ),
        SubmenuButton(
          leadingIcon: const Icon(Icons.palette_outlined),
          menuChildren: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 348, // two rows of six
                child: NoteSwatches(
                  current: color,
                  onPick: (c) {
                    setColor(c);
                    _cardMenu.close();
                  },
                ),
              ),
            ),
          ],
          child: const Text('Background color'),
        ),
        item(Icons.label_outline, 'Labels', () => showLabelPicker(context, ids)),
        item(
          allArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
          allArchived ? 'Unarchive' : 'Archive',
          archive,
        ),
        item(Icons.delete_outline, 'Delete', trash),
        const Divider(height: 9),
        if (!_selected.containsAll(ids))
          item(Icons.check_circle_outline, 'Select', () => setState(() => _selected.addAll(ids)))
        else
          item(Icons.select_all, 'Select all', selectAll),
      ];
    }

    final pinButton = IconButton(
      tooltip: allPinned ? 'Unpin' : 'Pin',
      isSelected: allPinned,
      icon: const Icon(Icons.push_pin_outlined),
      selectedIcon: const Icon(Icons.push_pin),
      onPressed: pin,
    );
    final labelButton = IconButton(
      tooltip: 'Labels',
      icon: const Icon(Icons.label_outline),
      onPressed: () => showLabelPicker(context, ids),
    );
    final archiveButton = IconButton(
      tooltip: allArchived ? 'Unarchive' : 'Archive',
      isSelected: allArchived,
      icon: const Icon(Icons.archive_outlined),
      selectedIcon: const Icon(Icons.unarchive_outlined),
      onPressed: archive,
    );
    Widget more(List<Widget> items) => MenuAnchor(
      builder: (context, ctl, _) => IconButton(
        tooltip: 'More options',
        icon: const Icon(Icons.more_vert),
        onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
      ),
      menuChildren: items,
    );

    // pin, remind, color, labels, archive, More
    final showColor = fits >= 6;
    final showRemind = fits >= 5;
    return [
      pinButton,
      if (showRemind) ReminderButton(current: null, onSet: remind, onClear: () => remind(null)),
      if (showColor) ColorButton(current: color, onPick: setColor),
      labelButton,
      archiveButton,
      more([
        if (!showRemind)
          item(
            Icons.add_alarm_outlined,
            'Remind me',
            () => showReminderSheet(context, current: null, onSet: remind, onClear: () => remind(null)),
          ),
        if (!showColor)
          item(
            Icons.palette_outlined,
            'Background color',
            () => showColorSheet(context, current: color, onPick: setColor),
          ),
        item(Icons.delete_outline, 'Delete', trash),
        item(Icons.select_all, 'Select all', selectAll),
      ]),
    ];
  }
}
