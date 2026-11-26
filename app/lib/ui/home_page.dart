import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/board_order.dart';
import '../core/protocol.dart';
import '../core/reminders.dart';
import '../core/roles.dart';
import '../data/media.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../notifications.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'board_drag.dart';
import 'check_motion.dart';
import 'brand.dart';
import 'create.dart';
import 'feedback.dart';
import 'labels_ui.dart';
import 'note_colors.dart';
import 'reminder_picker.dart';
import 'masonry.dart';
import 'note_card.dart';

enum Shelf {
  notes('Notes', Icons.lightbulb_outline, Icons.lightbulb),
  reminders('Reminders', Icons.notifications_none, Icons.notifications),
  labeled('Label', Icons.label_outline, Icons.label),
  archive('Archive', Icons.archive_outlined, Icons.archive),
  trash('Trash', Icons.delete_outline, Icons.delete);

  const Shelf(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Material's expanded window size class starts at 840dp: from there the
/// navigation drawer docks beside the content and holds the FAB.
bool isExpanded(BuildContext context) => MediaQuery.sizeOf(context).width >= 840;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Shelf _shelf = Shelf.notes;

  /// The label shown, on the label shelf.
  String? _label;

  /// The notes selected on the board, to act on together.
  final _selected = <String>{};
  final _selectionFocus = FocusNode(debugLabel: 'selection');

  void _toggle(String id, {bool? on}) {
    setState(() {
      if (on ?? !_selected.contains(id)) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
    // Escape and Ctrl+A act on the selection from here
    if (_selected.isNotEmpty) _selectionFocus.requestFocus();
  }

  void _clearSelection() => setState(_selected.clear);
  String _query = '';
  final _scaffold = GlobalKey<ScaffoldState>();
  final _gridKey = GlobalKey();
  late final _drag = BoardDrag(gridKey: _gridKey, cardFor: _liftedCard, onDrop: _onDrop)
    ..addListener(() {
      if (mounted) setState(() {});
    });
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // a drag does not survive the app going away
    _lifecycle = AppLifecycleListener(onHide: _drag.cancel, onPause: _drag.cancel);
  }

  /// After a drop, the order the board shows until the library has it (or
  /// a second passes), so nothing jumps back while the edit lands.
  ({List<String> pinned, List<String> others})? _held;
  Timer? _heldTimer;

  @override
  void dispose() {
    _heldTimer?.cancel();
    _selectionFocus.dispose();
    _lifecycle.dispose();
    _drag.dispose();
    super.dispose();
  }

  Widget _liftedCard(String id) {
    final lib = ref.read(libraryProvider).value ?? Library.empty;
    final n = lib.notes.where((n) => n.id == id).firstOrNull;
    return n == null ? const SizedBox.shrink() : NoteCard(note: n, library: lib);
  }

  /// The board's sections in order: by where you put notes, pinned first.
  ({List<Note> pinned, List<Note> others}) _sections(Library lib, List<Note> shown) {
    final pinned = shown.where((n) => lib.stateOf(n.id).pinned).toList();
    final others = shown.where((n) => !lib.stateOf(n.id).pinned).toList();
    return (pinned: pinned, others: others);
  }

  /// [ids] with [moved] put at [a].
  static ({List<String> pinned, List<String> others}) _place(
    ({List<String> pinned, List<String> others}) ids,
    String moved,
    Anchor a,
  ) {
    final pinned = [...ids.pinned]..remove(moved);
    final others = [...ids.others]..remove(moved);
    final dest = a.pinned ? pinned : others;
    final at = a.before == null ? -1 : dest.indexOf(a.before!);
    dest.insert(at < 0 ? dest.length : at, moved);
    return (pinned: pinned, others: others);
  }

  /// The note dropped at [a]: the fewest state edits that put it there.
  void _onDrop(String id, Anchor a) {
    final engine = ref.read(engineProvider);
    final lib = ref.read(libraryProvider).value;
    if (engine == null || lib == null) return;
    final base = _sections(lib, _shown(lib));
    final dest = (a.pinned ? base.pinned : base.others).where((n) => n.id != id).toList();
    final at = a.before == null ? dest.length : dest.indexWhere((n) => n.id == a.before);
    final ops = planMove(
      section: dest,
      states: lib.states,
      moved: id,
      index: at < 0 ? dest.length : at,
      toPinned: a.pinned,
      wasPinned: lib.stateOf(id).pinned,
    );
    _hold(_place((pinned: [for (final n in base.pinned) n.id], others: [for (final n in base.others) n.id]), id, a));
    unawaited(engine.edit([for (final o in ops) engine.op(Collections.noteState, o.note, o.field, o.value)]));
  }

  void _hold(({List<String> pinned, List<String> others}) order) {
    _heldTimer?.cancel();
    setState(() => _held = order);
    _heldTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _held = null);
    });
  }

  /// Moves [id] within its section by [by] places (Alt+arrows, and screen
  /// readers' Move earlier/later), or to the top.
  void _moveBy(String id, {int by = 0, bool top = false}) {
    final lib = ref.read(libraryProvider).value;
    if (lib == null) return;
    final base = _sections(lib, _shown(lib));
    final pinned = lib.stateOf(id).pinned;
    final list = pinned ? base.pinned : base.others;
    final from = list.indexWhere((n) => n.id == id);
    if (from < 0) return;
    final to = top ? 0 : (from + by).clamp(0, list.length - 1);
    if (to == from) return;
    final rest = [...list]..removeAt(from);
    _onDrop(id, (pinned: pinned, before: to < rest.length ? rest[to].id : null));
  }

  List<Note> _shown(Library lib) {
    final q = _query.trim().toLowerCase();
    bool hit(Note n) =>
        q.isEmpty ||
        n.label.toLowerCase().contains(q) ||
        lib.labelsOf(n.id).any((l) => l.name.toLowerCase().contains(q)) ||
        n.body.toLowerCase().contains(q) ||
        (lib.items[n.id] ?? const []).any((i) => i.text.toLowerCase().contains(q));
    bool onShelf(Note n) {
      final st = lib.stateOf(n.id);
      return switch (_shelf) {
        Shelf.trash => n.trashed.isNotEmpty,
        Shelf.archive => st.archived && n.trashed.isEmpty,
        Shelf.notes => !st.archived && n.trashed.isEmpty,
        Shelf.reminders => n.trashed.isEmpty && !st.reminderDone && reminderTime(st.reminder) != null,
        // a label finds its notes wherever they are, short of the trash
        Shelf.labeled => n.trashed.isEmpty && st.labels.contains(_label),
      };
    }

    // The Notes shelf in board order (where you put them; new notes on
    // top). Archive and trash newest made first. Editing never moves a note.
    final list = lib.notes.where((n) => onShelf(n) && hit(n)).toList();
    if (_shelf == Shelf.notes || _shelf == Shelf.labeled) {
      list.sort((a, b) => boardCompare(a, b, lib.stateOf(a.id), lib.stateOf(b.id)));
    } else if (_shelf == Shelf.reminders) {
      DateTime at(Note n) => reminderTime(lib.stateOf(n.id).reminder)!;
      list.sort((a, b) => at(a).compareTo(at(b)));
    } else {
      list.sort((a, b) => b.created.compareTo(a.created) != 0 ? b.created.compareTo(a.created) : b.id.compareTo(a.id));
    }
    return list;
  }

  void _pick(Shelf s, [String? label]) {
    setState(() {
      _shelf = s;
      _label = s == Shelf.labeled ? label : null;
      _selected.clear();
    });
    // a note made from here starts with this shelf's label or reminder
    newNoteDefaults.value = (label: _label, remind: s == Shelf.reminders);
  }

  /// The shelf's two sections, with their headers: pinned and the rest;
  /// on Reminders, what is still to come (soonest first) and what has
  /// passed (latest first).
  ({List<Note> pinned, List<Note> others, String first, String second}) _split(Library lib, List<Note> shown) {
    switch (_shelf) {
      case Shelf.reminders:
        final now = DateTime.now();
        final upcoming = [
          for (final n in shown)
            if (reminderTime(lib.stateOf(n.id).reminder)!.isAfter(now)) n,
        ];
        final earlier = [
          for (final n in shown.reversed)
            if (!reminderTime(lib.stateOf(n.id).reminder)!.isAfter(now)) n,
        ];
        return (pinned: upcoming, others: earlier, first: 'Upcoming', second: 'Earlier');
      case Shelf.notes || Shelf.labeled:
        final s = _sections(lib, shown);
        return (pinned: s.pinned, others: s.others, first: 'Pinned', second: 'Others');
      case Shelf.archive || Shelf.trash:
        return (pinned: <Note>[], others: shown, first: '', second: '');
    }
  }

  Future<void> _refresh() async {
    ref.read(engineProvider)?.nudge();
    // give the reconnect a moment; the grid updates on its own as changes land
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final status = ref.watch(syncStatusProvider).value;
    final shown = _shown(lib);
    final searching = _query.trim().isNotEmpty;
    final canDrag = _shelf == Shelf.notes && !searching;
    final split = _split(lib, shown);
    final base = (pinned: split.pinned, others: split.others);
    final byId = {for (final n in shown) n.id: n};
    final baseIds = (pinned: [for (final n in base.pinned) n.id], others: [for (final n in base.others) n.id]);

    // what the board shows: the library's order, a dropped note held in its
    // new place until the library agrees, a dragged note's slot where the
    // pointer would put it
    var ids = baseIds;
    if (_held case final held?) {
      final agrees = _same(held.pinned, baseIds.pinned) && _same(held.others, baseIds.others);
      if (agrees) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _held == held) setState(() => _held = null);
        });
      } else {
        ids = (
          pinned: [
            for (final i in held.pinned)
              if (byId.containsKey(i)) i,
          ],
          others: [
            for (final i in held.others)
              if (byId.containsKey(i)) i,
          ],
        );
        // anything new since the drop goes where the library puts it
        for (final i in baseIds.pinned) {
          if (!ids.pinned.contains(i) && !ids.others.contains(i)) ids.pinned.insert(0, i);
        }
        for (final i in baseIds.others) {
          if (!ids.pinned.contains(i) && !ids.others.contains(i)) ids.others.insert(0, i);
        }
      }
    }
    if (_drag.id case final dragged? when _drag.anchor != null) {
      if (!byId.containsKey(dragged)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _drag.cancel());
      } else {
        ids = _place(ids, dragged, _drag.anchor!);
      }
    }
    _drag.sections = ids;
    final pinned = [for (final i in ids.pinned) byId[i]!];
    final others = [for (final i in ids.others) byId[i]!];
    final dragging = _drag.active;
    // the selection, less anything no longer shown
    final selected = {
      for (final id in _selected)
        if (byId.containsKey(id)) id,
    };
    final wide = isExpanded(context);
    final theme = Theme.of(context);
    final firstSync = lib.notes.isEmpty && status?.phase != SyncPhase.online && status?.phase != SyncPhase.offline;
    final margin = wide ? 24.0 : 16.0;
    final showFab =
        !wide && _selected.isEmpty && (_shelf == Shelf.notes || _shelf == Shelf.reminders || _shelf == Shelf.labeled);
    // snackbars float above the compact FAB (56dp and its 16dp margin)
    snackbarClearance.value = showFab ? 56 + 16 : 0;

    // Material 3 section headers: title-small, sentence case
    Widget section(String label, String tag) => MasonryChild(
      key: ValueKey(tag),
      tag: tag,
      span: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    );

    Widget card(Note n) => MasonryChild(
      key: ValueKey(n.id),
      tag: n.id,
      child: RepaintBoundary(
        child: _Placeable(
          hidden: _drag.id == n.id,
          child: NoteCard(
            note: n,
            library: lib,
            onMove: canDrag ? (by) => _moveBy(n.id, by: by) : null,
            onMoveTop: canDrag ? () => _moveBy(n.id, top: true) : null,
            selected: selected.contains(n.id),
            selecting: selected.isNotEmpty,
            onSelect: () => _toggle(n.id),
            // where a long press lifts the card, lifting selects it
            longPressSelects: !canDrag,
          ),
        ),
      ),
    );

    // one grid for both sections, so a note keeps its card (and its glide)
    // when it is pinned or unpinned by dragging
    final showPinned = pinned.isNotEmpty || dragging;
    // Reminders heads its passed ones even with nothing still to come
    final showSecond =
        (showPinned && (others.isNotEmpty || dragging)) || (_shelf == Shelf.reminders && others.isNotEmpty);
    final grid = BoardGestures(
      drag: _drag,
      enabled: canDrag,
      onLifted: (id) => _toggle(id, on: true),
      child: Masonry(
        key: _gridKey,
        minColumnWidth: wide ? 240 : 160,
        spacing: 12,
        children: [
          if (showPinned) section(split.first, pinnedHeader),
          // nothing else pinned: somewhere to drop a note to pin it. It
          // unfolds as the drag starts and folds away as the note's slot
          // moves in (or the note is let go), so it seems to become the slot
          if (dragging && pinned.every((n) => n.id == _drag.id))
            MasonryChild(
              key: const ValueKey(pinZone),
              tag: pinZone,
              span: true,
              child: Fold(
                enter: true,
                leaving: pinned.isNotEmpty || _drag.phase == DragPhase.dropping,
                child: const PinDropZone(),
              ),
            ),
          for (final n in pinned) card(n),
          if (showSecond)
            section(split.second, othersHeader)
          else
            const MasonryChild(key: ValueKey('#top'), span: true, child: SizedBox(height: 8)),
          for (final n in others) card(n),
        ],
      ),
    );

    final content = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (selected.isNotEmpty)
          // a selection: the contextual top app bar, close, count, actions
          SliverAppBar(
            pinned: true,
            toolbarHeight: 64,
            backgroundColor: theme.colorScheme.surfaceContainer,
            leading: IconButton(tooltip: 'Clear selection', icon: const Icon(Icons.close), onPressed: _clearSelection),
            title: Text('${selected.length} selected'),
            actions: [..._selectionActions(lib, selected.toList(), shown, wide), const SizedBox(width: 4)],
          )
        else
          SliverAppBar(
            floating: true,
            snap: true,
            toolbarHeight: 72,
            titleSpacing: margin,
            automaticallyImplyLeading: false,
            centerTitle: true,
            title: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SearchBar(
                hintText: switch (_shelf) {
                  Shelf.notes => 'Search your notes',
                  Shelf.labeled => 'Search ${lib.labels.where((l) => l.id == _label).firstOrNull?.name ?? 'label'}',
                  _ => 'Search ${_shelf.label.toLowerCase()}',
                },
                elevation: const WidgetStatePropertyAll(0),
                leading: wide
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.search, color: theme.colorScheme.onSurface),
                      )
                    : IconButton(
                        icon: const Icon(Icons.menu),
                        tooltip: 'Open navigation',
                        onPressed: () => _scaffold.currentState?.openDrawer(),
                      ),
                trailing: const [_SyncMark(), _Account()],
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            bottom: firstSync
                ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                : null,
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(margin, 0, margin, 120),
          // centered and capped, so a very wide screen keeps the grid together
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: shown.isEmpty
                    ? (firstSync ? const SizedBox.shrink() : _Empty(shelf: _shelf, searching: _query.trim().isNotEmpty))
                    : grid,
              ),
            ),
          ),
        ),
      ],
    );

    final scaffold = Scaffold(
      key: _scaffold,
      drawer: wide ? null : _Drawer(shelf: _shelf, label: _label, onPick: _pick),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _Drawer(shelf: _shelf, label: _label, docked: true, onPick: _pick),
            Expanded(
              // files dropped on the board start a note of their own
              child: DropTarget(
                onDragDone: (d) async {
                  final picked = <NewFile>[
                    for (final f in d.files)
                      (name: f.name, size: await f.length(), path: f.path.isEmpty ? null : f.path, bytes: null),
                  ];
                  if (context.mounted) await newNoteWithFiles(context, picked);
                },
                child: RefreshIndicator(onRefresh: _refresh, child: content),
              ),
            ),
          ],
        ),
      ),
      // Compact and medium: the FAB menu (Note, List, Link, Image). Expanded:
      // the split button at the foot of the docked drawer.
      floatingActionButton: showFab ? const NewNoteFabMenu() : null,
    );
    // while selecting, Back and Escape clear it, Ctrl+A takes every note shown
    return PopScope(
      canPop: selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Focus(
        focusNode: _selectionFocus,
        child: CallbackShortcuts(
          bindings: {
            if (selected.isNotEmpty) ...{
              const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
              const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                  setState(() => _selected.addAll(shown.map((n) => n.id))),
            },
          },
          child: scaffold,
        ),
      ),
    );
  }

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

  /// The contextual bar's actions for [ids]. Compact windows keep three
  /// in the bar (Material's top app bar limit) and the rest under More.
  List<Widget> _selectionActions(Library lib, List<String> ids, List<Note> shown, bool wide) {
    if (ref.read(engineProvider) == null) return const [];
    final me = ref.read(sessionProvider).value?.user.id ?? '';
    final notes = [for (final id in ids) lib.notes.firstWhere((n) => n.id == id)];
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

    if (_shelf == Shelf.trash) {
      return [
        IconButton(
          tooltip: 'Restore',
          icon: const Icon(Icons.restore_from_trash_outlined),
          onPressed: () {
            _apply([for (final id in owned) _op(Collections.notes, id, 'trashed', '')], skipped: n - owned.length);
            _clearSelection();
          },
        ),
        IconButton(
          tooltip: 'Delete forever',
          icon: const Icon(Icons.delete_forever_outlined),
          onPressed: () async {
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
          },
        ),
      ];
    }

    final allPinned = ids.every((id) => lib.stateOf(id).pinned);
    final allArchived = ids.every((id) => lib.stateOf(id).archived);
    final colors = {for (final x in notes) x.color};
    final color = colors.length == 1 ? colors.first : '';

    void pin() {
      _apply([for (final id in ids) _op(Collections.noteState, id, 'pinned', !allPinned)]);
      _clearSelection();
    }

    void archive() {
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
    MenuItemButton trashItem() =>
        MenuItemButton(leadingIcon: const Icon(Icons.delete_outline), onPressed: trash, child: const Text('Delete'));
    MenuItemButton selectAllItem() => MenuItemButton(
      leadingIcon: const Icon(Icons.select_all),
      onPressed: () => setState(() => _selected.addAll(shown.map((x) => x.id))),
      child: const Text('Select all'),
    );
    Widget more(List<Widget> items) => MenuAnchor(
      builder: (context, ctl, _) => IconButton(
        tooltip: 'More options',
        icon: const Icon(Icons.more_vert),
        onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
      ),
      menuChildren: items,
    );

    if (wide) {
      return [
        pinButton,
        ReminderButton(current: null, onSet: remind, onClear: () => remind(null)),
        ColorButton(current: color, onPick: setColor),
        labelButton,
        archiveButton,
        more([trashItem(), selectAllItem()]),
      ];
    }
    return [
      pinButton,
      labelButton,
      archiveButton,
      more([
        MenuItemButton(
          leadingIcon: const Icon(Icons.add_alarm_outlined),
          onPressed: () => showReminderSheet(context, current: null, onSet: remind, onClear: () => remind(null)),
          child: const Text('Remind me'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.palette_outlined),
          onPressed: () => showColorSheet(context, current: color, onPick: setColor),
          child: const Text('Background color'),
        ),
        trashItem(),
        selectAllItem(),
      ]),
    ];
  }
}

/// The shelves. Docked beside the notes on an expanded screen, with the
/// new-note split button at its foot; slid out from the menu button
/// otherwise (the FAB menu creates notes there).
class _Drawer extends ConsumerWidget {
  const _Drawer({required this.shelf, required this.label, required this.onPick, this.docked = false});
  final Shelf shelf;
  final String? label;
  final bool docked;
  final void Function(Shelf shelf, [String? label]) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final labels = ref.watch(libraryProvider).value?.labels ?? const <Label>[];
    // every destination in order: the shelves, each label, Edit labels (an
    // action, never the selected one), then archive and trash
    final entries = <({Shelf? shelf, String? label})>[
      (shelf: Shelf.notes, label: null),
      (shelf: Shelf.reminders, label: null),
      for (final l in labels) (shelf: Shelf.labeled, label: l.id),
      (shelf: null, label: null),
      (shelf: Shelf.archive, label: null),
      (shelf: Shelf.trash, label: null),
    ];
    final selected = entries.indexWhere((e) => e.shelf == shelf && e.label == (shelf == Shelf.labeled ? label : null));
    NavigationDrawerDestination dest(Shelf s, [String? name]) => NavigationDrawerDestination(
      icon: Icon(s.icon),
      selectedIcon: Icon(s.selectedIcon),
      label: Flexible(child: Text(name ?? s.label, overflow: TextOverflow.ellipsis)),
    );
    // Material's drawer section header and divider: title small in on
    // surface variant, inset to the destinations' 28dp
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 16, 10),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
    const divider = Padding(padding: EdgeInsets.symmetric(horizontal: 28), child: Divider());
    final drawer = NavigationDrawer(
      selectedIndex: selected < 0 ? null : selected,
      backgroundColor: docked ? theme.colorScheme.surface : null,
      onDestinationSelected: (i) {
        final e = entries[i];
        if (!docked) Navigator.of(context).pop();
        if (e.shelf == null) {
          unawaited(showEditLabels(context));
        } else {
          onPick(e.shelf!, e.label);
        }
      },
      children: [
        header('chit'),
        dest(Shelf.notes),
        dest(Shelf.reminders),
        divider,
        if (labels.isNotEmpty) header('Labels'),
        for (final l in labels) dest(Shelf.labeled, l.name),
        NavigationDrawerDestination(
          icon: Icon(labels.isEmpty ? Icons.new_label_outlined : Icons.edit_outlined),
          label: Text(labels.isEmpty ? 'Create label' : 'Edit labels'),
        ),
        divider,
        dest(Shelf.archive),
        dest(Shelf.trash),
      ],
    );
    if (!docked) return drawer;
    return SizedBox(
      width: 300,
      child: Column(
        children: [
          Expanded(child: drawer),
          ColoredBox(
            color: theme.colorScheme.surface,
            child: const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 20), child: NewNoteSplitButton()),
          ),
        ],
      ),
    );
  }
}

/// The account: an avatar in the search bar, with the account and sign-out
/// in its menu.
class _Account extends ConsumerWidget {
  const _Account();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final name = session.user.display;
    return MenuAnchor(
      alignmentOffset: const Offset(-160, 8),
      builder: (context, ctl, _) => IconButton(
        tooltip: 'Account: $name',
        onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
        icon: CircleAvatar(
          radius: 15,
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.account_circle_outlined),
          onPressed: null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name),
              Text(Uri.parse(session.server).host, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (notificationsSupported) ...[const Divider(height: 1), const _NotifyToggle(), const _BackgroundSync()],
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout),
          onPressed: () => ref.read(sessionProvider.notifier).signOut(),
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}

/// Whether this phone tells of other people's edits to shared notes.
final _notifyActivityProvider = FutureProvider<bool>((ref) => activityEnabled(ref.watch(replicaProvider)));

class _NotifyToggle extends ConsumerWidget {
  const _NotifyToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(_notifyActivityProvider).value ?? true;
    return CheckboxMenuButton(
      value: on,
      closeOnActivate: false,
      onChanged: (v) async {
        await setActivityEnabled(ref.read(replicaProvider), v ?? false);
        if (v ?? false) await askNotificationPermission();
        ref.invalidate(_notifyActivityProvider);
      },
      child: const Text('Notify me about shared edits'),
    );
  }
}

const _power = MethodChannel('chit/power');

/// Whether Android leaves the background catch-up alone (no battery
/// optimization); null where it doesn't apply.
final _exemptProvider = FutureProvider<bool?>((ref) async {
  try {
    return await _power.invokeMethod<bool>('exempt');
  } on MissingPluginException {
    return null;
  }
});

/// Offers to exempt chit from battery optimization, which otherwise
/// stretches the 15-minute catch-up to hours. Gone once granted.
class _BackgroundSync extends ConsumerWidget {
  const _BackgroundSync();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(_exemptProvider).value != false) return const SizedBox.shrink();
    return MenuItemButton(
      leadingIcon: const Icon(Icons.battery_saver_outlined),
      onPressed: () async {
        await _power.invokeMethod<void>('ask');
        ref.invalidate(_exemptProvider);
      },
      child: const Text('Sync in the background'),
    );
  }
}

/// Online, sending, or offline, as one quiet icon.
class _SyncMark extends ConsumerWidget {
  const _SyncMark();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(pendingProvider).value ?? 0;
    final (icon, tip) = switch (status?.phase) {
      SyncPhase.online when pending > 0 => (Icons.cloud_upload_outlined, 'Sending $pending'),
      SyncPhase.online => (Icons.cloud_done_outlined, 'Up to date'),
      SyncPhase.offline => (
        Icons.cloud_off_outlined,
        'Offline: ${status!.error}${pending > 0 ? ' · $pending waiting' : ''}',
      ),
      _ => (Icons.cloud_sync_outlined, 'Connecting'),
    };
    return Tooltip(
      message: tip,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// An empty shelf: an Expressive shape with the shelf's glyph in it.
class _Empty extends StatelessWidget {
  const _Empty({required this.shelf, required this.searching});
  final Shelf shelf;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = searching
        ? 'No notes match'
        : switch (shelf) {
            Shelf.notes => 'Notes you add appear here',
            Shelf.archive => 'Archived notes appear here',
            Shelf.trash => 'No notes in the trash',
            Shelf.reminders => 'Notes with upcoming reminders appear here',
            Shelf.labeled => 'No notes with this label yet',
          };
    return Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Column(
        children: [
          // an empty board is where the mark lives, bare, in primary: chit,
          // waiting for its first note; other shelves and searches keep their
          // glyph on the Expressive cookie
          if (shelf == Shelf.notes && !searching)
            const ChitMark(size: 120, semanticLabel: null)
          else
            DecoratedBox(
              decoration: ShapeDecoration(
                color: scheme.primaryContainer,
                shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
              ),
              child: SizedBox.square(
                dimension: 96,
                child: Icon(searching ? Icons.search_off : shelf.icon, size: 40, color: scheme.onPrimaryContainer),
              ),
            ),
          const SizedBox(height: 24),
          Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A card that may be out on a drag: kept in the tree (its state, its
/// pending checks) but unseen, with its slot drawn in its place.
class _Placeable extends StatelessWidget {
  const _Placeable({required this.hidden, required this.child});
  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = Theme.of(context).cardTheme.shape;
    final radius = shape is RoundedRectangleBorder ? shape.borderRadius : BorderRadius.circular(12);
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: hidden ? 1 : 0,
            duration: Durations.short2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: radius,
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
          ),
        ),
        Visibility(visible: !hidden, maintainState: true, maintainAnimation: true, maintainSize: true, child: child),
      ],
    );
  }
}

/// Somewhere to drop a note to pin it, while dragging and nothing is
/// pinned: a dashed outline (the drop-here sign) in the card shape, a pin in
/// a tonal circle, and what it does.
class PinDropZone extends StatelessWidget {
  const PinDropZone({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = theme.cardTheme.shape;
    final radius = shape is RoundedRectangleBorder
        ? shape.borderRadius.resolve(Directionality.of(context))
        : BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CustomPaint(
        foregroundPainter: _DashedOutline(color: scheme.outline, radius: radius),
        child: Container(
          height: 88,
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: radius),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 16,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: scheme.secondaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.push_pin_outlined, size: 20, color: scheme.onSecondaryContainer),
              ),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text('Drop here to pin', style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface)),
                    Text(
                      'Pinned notes stay on top',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dashed rounded-rectangle outline.
class _DashedOutline extends CustomPainter {
  const _DashedOutline({required this.color, required this.radius});
  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(radius.toRRect(Offset.zero & size).deflate(0.75));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline old) => old.color != color || old.radius != radius;
}
