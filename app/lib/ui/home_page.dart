import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/board_order.dart';
import '../core/protocol.dart';
import '../core/reminders.dart';
import '../core/roles.dart';
import '../data/media.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'board_drag.dart';
import 'check_motion.dart';
import 'brand.dart';
import 'create.dart';
import 'expressive.dart';
import 'feedback.dart';
import 'haptics.dart';
import 'labels_ui.dart';
import 'note_colors.dart';
import 'reminder_picker.dart';
import 'settings.dart';
import 'masonry.dart';
import 'nav_rail.dart';
import 'note_routes.dart';
import 'note_card.dart';

/// What the chips under the search bar narrow a shelf to (labels are
/// chips there too; those pick the label's own shelf).
enum NoteFilter {
  lists('Lists'),
  images('Images'),
  shared('Shared');

  const NoteFilter(this.label);
  final String label;
}

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

  /// On an expanded window, whether the rail is collapsed to its 96dp form.
  bool _railCollapsed = false;

  /// The notes selected on the board, to act on together.
  final _selected = <String>{};
  final _selectionFocus = FocusNode(debugLabel: 'selection');

  void _toggle(String id, {bool? on}) {
    // a tap's toggle is felt; a lift already was
    if (on == null) tick();
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

  /// The card menu (a right click): one menu for the board, opened where
  /// the pointer is, for the note it was opened on.
  final _cardMenu = MenuController();
  final _cardMenuKey = GlobalKey();
  String? _menuNote;

  void _openCardMenu(String id, Offset at) {
    setState(() => _menuNote = id);
    // once the menu has that note's items
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _cardMenuKey.currentContext?.findRenderObject();
      if (anchor is RenderBox && anchor.attached) _cardMenu.open(position: anchor.globalToLocal(at));
    });
  }

  String _query = '';
  final _filters = <NoteFilter>{};

  /// Whether the shelf is narrowed, by words or by chips.
  bool get _narrowed => _query.trim().isNotEmpty || _filters.isNotEmpty;
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Whether the modal rail is up. Android only asks the app about Back when
  /// told a pop is pending, and a drawer's own history entry doesn't say so
  /// on the first page: without this, Back would leave the app.
  bool _railOpen = false;
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

  /// The note open above the board: on expanded windows it is in the detail
  /// pane, which the board leaves room for.
  String? _openNote;
  GoRouter? _router;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.of(context);
    if (router == _router) return;
    _router?.routerDelegate.removeListener(_routeChanged);
    _router = router..routerDelegate.addListener(_routeChanged);
    _openNote = openNoteId(router);
  }

  void _routeChanged() {
    final id = openNoteId(_router!);
    if (id != _openNote && mounted) setState(() => _openNote = id);
  }

  /// After a drop, the order the board shows until the library has it (or
  /// a second passes), so nothing jumps back while the edit lands.
  ({List<String> pinned, List<String> others})? _held;
  Timer? _heldTimer;

  @override
  void dispose() {
    _heldTimer?.cancel();
    _router?.routerDelegate.removeListener(_routeChanged);
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
    final me = ref.read(sessionProvider).value?.user.id ?? '';
    // every chip that is on has to hold
    bool passes(Note n) => _filters.every(
      (f) => switch (f) {
        NoteFilter.lists => n.isList,
        NoteFilter.images => (lib.attachments[n.id] ?? const <Attachment>[]).any((a) => a.isImage),
        NoteFilter.shared => n.owner != me || (lib.members[n.id]?.isNotEmpty ?? false),
      },
    );
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
    final list = lib.notes.where((n) => onShelf(n) && hit(n) && passes(n)).toList();
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
    final searching = _narrowed;
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
    // Material's window size classes: compact below 600dp (navigation
    // behind the menu button), medium to 840 (the collapsed rail), expanded
    // from there (the expanded rail, which its menu button collapses)
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 600;
    // the detail pane's room at the window's end, while a note is open
    final detail = wide && _openNote != null ? detailPaneWidth(width) + paneSpacer : 0.0;
    // the rail gives way to the pane where the board would be squeezed
    // (to under two columns)
    final expandedRail = wide && !_railCollapsed && width - NavRail.expandedWidth - detail >= 560;
    // margins: 16dp on compact windows, 24dp from medium up
    final margin = compact ? 16.0 : 24.0;
    // the expanded rail holds the new-note button; otherwise it floats
    final showFab =
        !expandedRail &&
        _selected.isEmpty &&
        (_shelf == Shelf.notes || _shelf == Shelf.reminders || _shelf == Shelf.labeled);
    // snackbars float above the FAB (56dp and its 16dp margin), or the
    // selection toolbar that takes its place (64dp)
    snackbarClearance.value = _selected.isNotEmpty ? 64 + 16 : (showFab ? 56 + 16 : 0);
    // the pane beside the rail: what the selection toolbar centers in
    final railWidth = compact ? 0.0 : (expandedRail ? NavRail.expandedWidth : NavRail.collapsedWidth);
    final paneWidth = width - railWidth - detail;

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
          overhang: _checkOverhang,
          child: NoteCard(
            overhang: _checkOverhang,
            note: n,
            library: lib,
            onMove: canDrag ? (by) => _moveBy(n.id, by: by) : null,
            onMoveTop: canDrag ? () => _moveBy(n.id, top: true) : null,
            open: wide && _openNote == n.id,
            selected: selected.contains(n.id),
            selecting: selected.isNotEmpty,
            onSelect: () => _toggle(n.id),
            onMenu: (at) => _openCardMenu(n.id, at),
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
    final board = BoardGestures(
      drag: _drag,
      enabled: canDrag,
      onLifted: (id) => _toggle(id, on: true),
      child: Masonry(
        key: _gridKey,
        minColumnWidth: wide ? 240 : 160,
        spacing: 12,
        overhang: _checkOverhang,
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

    // a right click's menu acts on the selection the card is part of, or
    // on the card alone
    final menuIds = switch (_menuNote) {
      final id? when selected.contains(id) => selected.toList(),
      final id? when byId.containsKey(id) => [id],
      _ => const <String>[],
    };
    final grid = MenuAnchor(
      key: _cardMenuKey,
      controller: _cardMenu,
      menuChildren: menuIds.isEmpty ? const [] : _noteActions(lib, menuIds, shown, menu: true),
      child: board,
    );

    final content = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
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
              // compact windows have no navigation to open: Reminders and
              // the labels are chips below, Archive and Trash are in the
              // account menu, and from those two this leads back to Notes
              leading: compact && (_shelf == Shelf.archive || _shelf == Shelf.trash)
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back to notes',
                      onPressed: () => _pick(Shelf.notes),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.search, color: theme.colorScheme.onSurface),
                    ),
              trailing: [
                const _SyncMark(),
                _Account(shelf: _shelf, onPick: compact ? _pick : null),
              ],
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          // filter chips ride with the search bar: kinds of note, then the
          // labels, one tap each (none in the trash)
          bottom: _shelf == Shelf.trash
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: _FilterChips(
                    margin: margin,
                    filters: _filters,
                    onFilter: (f, on) {
                      tick();
                      setState(() => on ? _filters.add(f) : _filters.remove(f));
                    },
                    // Reminders and the labels are shelves of their own,
                    // reached from Notes (and from each other)
                    reminders: _shelf == Shelf.archive ? null : _shelf == Shelf.reminders,
                    onReminders: (on) => _pick(on ? Shelf.reminders : Shelf.notes),
                    labels: _shelf == Shelf.archive ? const [] : lib.labels,
                    label: _shelf == Shelf.labeled ? _label : null,
                    onLabel: (id, on) => on ? _pick(Shelf.labeled, id) : _pick(Shelf.notes),
                  ),
                ),
        ),
        SliverPadding(
          // the grid insets its own columns by the check's overhang
          padding: EdgeInsets.fromLTRB(margin - _checkOverhang, 0, margin, 120),
          // centered and capped, so a very wide screen keeps the grid together
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(left: _checkOverhang),
                        child: firstSync
                            // the first load: Material's loading indicator, where the notes will be
                            ? const Padding(
                                padding: EdgeInsets.only(top: 120),
                                child: Center(child: LoadingIndicator(contained: true)),
                              )
                            : _Empty(shelf: _shelf, searching: _narrowed),
                      )
                    : grid,
              ),
            ),
          ),
        ),
      ],
    );

    final scaffold = Scaffold(
      key: _scaffold,
      onDrawerChanged: (open) => setState(() => _railOpen = open),
      // medium: the expanded rail comes over the content, from the
      // collapsed rail's menu button (compact has no rail at all)
      drawer: wide || compact
          ? null
          : NavRail(
              mode: RailMode.modal,
              shelf: _shelf,
              label: _label,
              onPick: _pick,
              onMenu: () => _scaffold.currentState?.closeDrawer(),
            ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compact)
              NavRail(
                mode: expandedRail ? RailMode.expanded : RailMode.collapsed,
                shelf: _shelf,
                label: _label,
                onPick: _pick,
                onMenu: wide
                    ? () => setState(() => _railCollapsed = !_railCollapsed)
                    : () => _scaffold.currentState?.openDrawer(),
                footer: const Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, 20), child: NewNoteSplitButton()),
              ),
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
                child: PullToRefresh(onRefresh: _refresh, child: content),
              ),
            ),
            // the detail pane's room (the pane itself is the note's route)
            AnimatedContainer(duration: Durations.medium4, curve: Easing.emphasizedDecelerate, width: detail),
          ],
        ),
      ),
      // The FAB menu (Note, List, Link, Image), except beside the expanded
      // rail, which has the split button at its foot. A selection puts its
      // toolbar in the FAB's place: the FAB shrinks away and the toolbar
      // grows in at the pane's center, on the scaffold's own FAB motion, so
      // snackbars and the mini player clear it as they clear the FAB.
      floatingActionButton: selected.isNotEmpty
          ? KeyedSubtree(
              key: const ValueKey('selection'),
              child: _selectionBar(lib, selected.toList(), shown, paneWidth - 32),
            )
          : (showFab ? const NewNoteFabMenu() : null),
      floatingActionButtonLocation: selected.isNotEmpty
          ? _BoardFloat(start: railWidth, end: detail, centered: true)
          : (detail > 0 ? _BoardFloat(start: 0, end: detail, centered: false) : null),
    );
    // Back closes the modal rail, then clears the selection, then (on a
    // compact window) returns to Notes; while
    // selecting, Escape clears it too and Ctrl+A takes every note shown
    return PopScope(
      canPop: selected.isEmpty && !_railOpen && !(compact && _shelf != Shelf.notes),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_scaffold.currentState?.isDrawerOpen ?? false) {
          _scaffold.currentState?.closeDrawer();
        } else if (selected.isNotEmpty) {
          _clearSelection();
        } else {
          // on a phone the other shelves are a step in from Notes
          _pick(Shelf.notes);
        }
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
  List<Widget> _noteActions(Library lib, List<String> ids, List<Note> shown, {int fits = 0, bool menu = false}) {
    if (ref.read(engineProvider) == null) return const [];
    final me = ref.read(sessionProvider).value?.user.id ?? '';
    final notes = [for (final id in ids) ?lib.notes.where((n) => n.id == id).firstOrNull];
    if (notes.isEmpty) return const [];
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

/// The row of filter chips under the search bar, in its width: Material's
/// filter chips (32dp, 8dp apart), scrolling sideways when they run out of
/// room.
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.margin,
    required this.filters,
    required this.onFilter,
    required this.reminders,
    required this.onReminders,
    required this.labels,
    required this.label,
    required this.onLabel,
  });
  final double margin;
  final Set<NoteFilter> filters;
  final void Function(NoteFilter filter, bool on) onFilter;

  /// Whether the Reminders shelf is the one shown; null for no such chip.
  final bool? reminders;
  final ValueChanged<bool> onReminders;
  final List<Label> labels;
  final String? label;
  final void Function(String id, bool on) onLabel;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (reminders case final on?)
        FilterChip(
          avatar: on ? null : const Icon(Icons.notifications_outlined),
          label: const Text('Reminders'),
          selected: on,
          onSelected: (v) {
            tick();
            onReminders(v);
          },
        ),
      for (final f in NoteFilter.values)
        FilterChip(label: Text(f.label), selected: filters.contains(f), onSelected: (on) => onFilter(f, on)),
      for (final l in labels)
        FilterChip(
          avatar: label == l.id ? null : const Icon(Icons.label_outline),
          label: Text(l.name),
          selected: label == l.id,
          onSelected: (on) {
            tick();
            onLabel(l.id, on);
          },
        ),
    ];
    return SizedBox(
      height: 48,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 720 + margin * 2),
          child: ScrollConfiguration(
            behavior: anyPointerScroll(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(margin, 0, margin, 8),
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => Center(child: chips[i]),
            ),
          ),
        ),
      ),
    );
  }
}

/// How far the selection check hangs off a card's corner, into the grid's
/// gap: room the grid gives each card's box so the check is under the
/// pointer there.
const _checkOverhang = 10.0;

/// The FAB slot's place over the board, which has a rail [start] wide
/// before it and the detail pane's [end] after it: afloat at the foot,
/// [centered] in the board (the selection toolbar) or at its end (the FAB).
class _BoardFloat extends StandardFabLocation with FabFloatOffsetY {
  const _BoardFloat({required this.start, required this.end, required this.centered});
  final double start;
  final double end;
  final bool centered;

  @override
  double getOffsetX(ScaffoldPrelayoutGeometry g, double adjustment) {
    final rtl = g.textDirection == TextDirection.rtl;
    final left = rtl ? end : start, right = rtl ? start : end;
    final fab = g.floatingActionButtonSize.width;
    if (centered) return left + (g.scaffoldSize.width - left - right - fab) / 2;
    return rtl
        ? left + kFloatingActionButtonMargin + g.minInsets.left
        : g.scaffoldSize.width - right - kFloatingActionButtonMargin - g.minInsets.right - fab;
  }

  @override
  bool operator ==(Object other) =>
      other is _BoardFloat && other.start == start && other.end == end && other.centered == centered;

  @override
  int get hashCode => Object.hash(start, end, centered);
}

/// The account: an avatar at the search bar's end, and its menu, hung from
/// the bar's end too. The menu is Expressive's segmented kind: who is
/// signed in and how the sync stands; on compact windows the shelves that
/// have no chip; then settings and signing out.
class _Account extends ConsumerWidget {
  const _Account({required this.shelf, this.onPick});
  final Shelf shelf;

  /// On compact windows, which have no rail: the way to Archive and Trash.
  final void Function(Shelf shelf)? onPick;

  static const _width = 280.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = session.user.display;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final (icon, state) = _syncState(ref);
    return MenuAnchor(
      style: segmentedMenuStyle,
      // its end on the search bar's end: the button is 40dp, 8dp in from it
      alignmentOffset: const Offset(40 + 8 - _width, 12),
      builder: (context, ctl, _) => SizedBox.square(
        dimension: 40,
        child: IconButton(
          tooltip: 'Account: $name',
          padding: EdgeInsets.zero,
          onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
          icon: CircleAvatar(
            radius: 15,
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
            child: Text(initial),
          ),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: _width,
          child: SegmentedMenu(
            groups: [
              // who is signed in, and where: a header, not something to press
              [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primaryContainer,
                        foregroundColor: scheme.onPrimaryContainer,
                        child: Text(initial, style: theme.textTheme.titleMedium),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurface),
                            ),
                            Text(
                              Uri.parse(session.server).host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // how the sync stands, in words (the bar's mark says it small)
                Padding(
                  // its icon over the items' icons below
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(
                    children: [
                      Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(state, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    ],
                  ),
                ),
              ],
              if (onPick case final pick?)
                [
                  for (final s in const [Shelf.archive, Shelf.trash])
                    SegmentedMenuItem(icon: s.icon, label: s.label, selected: shelf == s, onPressed: () => pick(s)),
                ],
              [
                SegmentedMenuItem(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  onPressed: () => showSettings(context),
                ),
                SegmentedMenuItem(
                  icon: Icons.logout,
                  label: 'Sign out',
                  onPressed: () => ref.read(sessionProvider.notifier).signOut(),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The sync's state as an icon and a few words.
(IconData, String) _syncState(WidgetRef ref) {
  final status = ref.watch(syncStatusProvider).value;
  final pending = ref.watch(pendingProvider).value ?? 0;
  return switch (status?.phase) {
    SyncPhase.online when pending > 0 => (Icons.cloud_upload_outlined, 'Sending $pending'),
    SyncPhase.online => (Icons.cloud_done_outlined, 'Up to date'),
    SyncPhase.offline => (
      Icons.cloud_off_outlined,
      'Offline: ${status!.error}${pending > 0 ? ' · $pending waiting' : ''}',
    ),
    _ => (Icons.cloud_sync_outlined, 'Connecting'),
  };
}

/// Online, sending, or offline, as one quiet icon.
class _SyncMark extends ConsumerWidget {
  const _SyncMark();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, tip) = _syncState(ref);
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
  const _Placeable({required this.hidden, required this.overhang, required this.child});
  final bool hidden;

  /// The child's box starts this far up and left of its card.
  final double overhang;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = Theme.of(context).cardTheme.shape;
    final radius = shape is RoundedRectangleBorder ? shape.borderRadius : BorderRadius.circular(12);
    return Stack(
      children: [
        Positioned.fill(
          top: overhang,
          left: overhang,
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
