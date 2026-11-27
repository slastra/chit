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
import 'layout.dart';
import 'note_colors.dart';
import 'reminder_picker.dart';
import 'settings.dart';
import 'masonry.dart';
import 'nav_rail.dart';
import 'note_routes.dart';
import 'note_card.dart';
import 'shelf.dart';
import 'theme.dart';

part 'board_parts.dart';
part 'home_bar.dart';
part 'note_actions.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> with _NoteActions {
  @override
  Shelf _shelf = Shelf.notes;

  /// The label shown, on the label shelf.
  String? _label;

  /// On an expanded window, whether the rail is collapsed to its 96dp form.
  bool _railCollapsed = false;

  /// The notes selected on the board, to act on together.
  @override
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

  @override
  void _clearSelection() => setState(_selected.clear);

  /// The card menu (a right click): one menu for the board, opened where
  /// the pointer is, for the note it was opened on.
  @override
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
    HardwareKeyboard.instance.addHandler(_onKey);
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

  // ---- search and keys ------------------------------------------------------

  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');

  /// The board's keys, whatever has focus (or nothing does): Ctrl+F and /
  /// to search, Ctrl+N for a new note. Only while the board is the page in
  /// front, and / only when it would not be typed into a field.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final typing = FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    if ((ctrl && e.logicalKey == LogicalKeyboardKey.keyF) ||
        (!ctrl && !typing && e.logicalKey == LogicalKeyboardKey.slash)) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
      return true;
    }
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyN && !keys.isShiftPressed) {
      unawaited(startNote(context, NewKind.note));
      return true;
    }
    return false;
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  /// Every note in the trash goes for good, after asking: what the Trash
  /// shelf's Empty trash does. Only the reader's own notes can go.
  Future<void> _emptyTrash(List<Note> shown) async {
    final me = ref.read(sessionProvider).value?.user.id ?? '';
    final mine = [
      for (final n in shown)
        if (n.owner == me) n.id,
    ];
    if (mine.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined),
        title: const Text('Empty the trash?'),
        content: Text(
          mine.length == 1
              ? 'The note in the trash goes from every device, for good.'
              : 'All ${mine.length} notes in the trash go from every device, for good.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Empty trash')),
        ],
      ),
    );
    if (ok != true) return;
    _apply([for (final id in mine) _op(Collections.notes, id, 'deleted', true)], skipped: shown.length - mine.length);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _search.dispose();
    _searchFocus.dispose();
    _heldTimer?.cancel();
    _router?.routerDelegate.removeListener(_routeChanged);
    _selectionFocus.dispose();
    _lifecycle.dispose();
    _drag.dispose();
    super.dispose();
  }

  Widget _liftedCard(String id) {
    final lib = ref.read(libraryProvider).value ?? Library.empty;
    if (lib.note(id) == null) return const SizedBox.shrink();
    return NoteCard(view: lib.viewOf(id), me: ref.read(sessionProvider).value?.user.id ?? '');
  }

  /// The board's cards as last built, by note: a card whose note and place
  /// on the board are unchanged is handed back as the same widget, which
  /// Flutter then skips. Typing a search, a change to another note, or a
  /// sync of nothing new no longer rebuilds every card.
  final _cards = <String, ({NoteView view, Object how, Widget card})>{};

  Widget _card(NoteView view, String me, ({bool canDrag, bool open, bool selected, bool selecting}) how) {
    final id = view.note.id;
    final last = _cards[id];
    if (last != null && last.view == view && last.how == (how, me)) return last.card;
    final card = NoteCard(
      overhang: _checkOverhang,
      view: view,
      me: me,
      onMove: how.canDrag ? (by) => _moveBy(id, by: by) : null,
      onMoveTop: how.canDrag ? () => _moveBy(id, top: true) : null,
      open: how.open,
      selected: how.selected,
      selecting: how.selecting,
      onSelect: () => _toggle(id),
      onMenu: (at) => _openCardMenu(id, at),
      // where a long press lifts the card, lifting selects it
      longPressSelects: !how.canDrag,
    );
    _cards[id] = (view: view, how: (how, me), card: card);
    return card;
  }

  /// The shelf as it stands: its notes, ordered, in their two sections.
  final _memo = ShelfMemo();
  ShelfView _view(Library lib) => _memo.of(lib, (
    shelf: _shelf,
    label: _label,
    query: _query,
    filters: _filters,
    me: ref.read(sessionProvider).value?.user.id ?? '',
  ));

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
    final view = _view(lib);
    final base = (pinned: view.first, others: view.second);
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
    final view = _view(lib);
    final base = (pinned: view.first, others: view.second);
    final pinned = lib.stateOf(id).pinned;
    final list = pinned ? base.pinned : base.others;
    final from = list.indexWhere((n) => n.id == id);
    if (from < 0) return;
    final to = top ? 0 : (from + by).clamp(0, list.length - 1);
    if (to == from) return;
    final rest = [...list]..removeAt(from);
    _onDrop(id, (pinned: pinned, before: to < rest.length ? rest[to].id : null));
  }

  void _pick(Shelf s, [String? label]) {
    setState(() {
      _shelf = s;
      _label = s == Shelf.labeled ? label : null;
      _selected.clear();
      // a new shelf starts clean: no words, no chips
      _search.clear();
      _query = '';
      _filters.clear();
    });
    // a note made from here starts with this shelf's label or reminder
    newNoteDefaults.value = (label: _label, remind: s == Shelf.reminders);
  }

  Future<void> _refresh() async {
    ref.read(engineProvider)?.nudge();
    // give the reconnect a moment; the grid updates on its own as changes land
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    // only whether the first sync is still under way, not every status
    final syncing = ref.watch(
      syncStatusProvider.select((s) => s.value?.phase != SyncPhase.online && s.value?.phase != SyncPhase.offline),
    );
    final me = ref.watch(sessionProvider.select((s) => s.value?.user.id ?? ''));
    // cards of notes gone from the library go too
    _cards.removeWhere((id, _) => lib.note(id) == null);
    final view = _view(lib);
    final shown = view.shown;
    final searching = _narrowed;
    final canDrag = _shelf == Shelf.notes && !searching;
    final base = (pinned: view.first, others: view.second);
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
        final placed = {...ids.pinned, ...ids.others};
        ids.pinned.insertAll(0, [
          for (final i in baseIds.pinned)
            if (!placed.contains(i)) i,
        ]);
        ids.others.insertAll(0, [
          for (final i in baseIds.others)
            if (!placed.contains(i)) i,
        ]);
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
    // the selection, less anything no longer shown (another device trashed
    // it, a filter hid it): kept that way, so every reader agrees
    _selected.removeWhere((id) => !byId.containsKey(id));
    final selected = _selected;
    final wide = isExpanded(context);
    final theme = Theme.of(context);
    final firstSync = lib.notes.isEmpty && syncing;
    // Material's window size classes: compact below 600dp (navigation
    // behind the menu button), medium to 840 (the collapsed rail), expanded
    // from there (the expanded rail, which its menu button collapses)
    final width = MediaQuery.sizeOf(context).width;
    final compact = isCompactWidth(width);
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
        selected.isEmpty &&
        (_shelf == Shelf.notes || _shelf == Shelf.reminders || _shelf == Shelf.labeled);
    // snackbars float above the FAB (56dp and its 16dp margin), or the
    // selection toolbar that takes its place (64dp)
    snackbarClearance = selected.isNotEmpty ? 64 + 16 : (showFab ? 56 + 16 : 0);
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
          child: _card(lib.viewOf(n.id), me, (
            canDrag: canDrag,
            open: wide && _openNote == n.id,
            selected: selected.contains(n.id),
            selecting: selected.isNotEmpty,
          )),
        ),
      ),
    );

    // one grid for both sections, so a note keeps its card (and its glide)
    // when it is pinned or unpinned by dragging
    final showPinned = pinned.isNotEmpty || dragging;
    // Reminders heads its passed ones even with nothing still to come
    // Reminders, and a search reaching the archive, head their second part
    // even with nothing in the first
    final showSecond =
        (showPinned && (others.isNotEmpty || dragging)) ||
        ((_shelf == Shelf.reminders || view.secondLabel == 'Archive') && others.isNotEmpty);
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
          if (showPinned) section(view.firstLabel, pinnedHeader),
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
            section(view.secondLabel, othersHeader)
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
      onClose: () {
        if (_menuNote != null) setState(() => _menuNote = null);
      },
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
              controller: _search,
              focusNode: _searchFocus,
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
                if (_query.isNotEmpty)
                  IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close), onPressed: _clearSearch),
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
                    // (beside the expanded rail, which lists them, only the
                    // kinds: the rest would say the same thing twice)
                    reminders: _shelf == Shelf.archive || expandedRail ? null : _shelf == Shelf.reminders,
                    onReminders: (on) => _pick(on ? Shelf.reminders : Shelf.notes),
                    labels: _shelf == Shelf.archive || expandedRail ? const [] : lib.labels,
                    label: _shelf == Shelf.labeled ? _label : null,
                    onLabel: (id, on) => on ? _pick(Shelf.labeled, id) : _pick(Shelf.notes),
                  ),
                ),
        ),
        // Archive and Trash say where you are (on a phone the search bar's
        // hint is the only other sign, gone once you type); Trash can be
        // emptied in one go
        if (_shelf == Shelf.archive || _shelf == Shelf.trash)
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(margin + 4, 4, margin, 0),
                  child: SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(child: Text(_shelf.label, style: theme.textTheme.titleLarge)),
                        if (_shelf == Shelf.trash && shown.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => _emptyTrash(shown),
                            icon: const Icon(Icons.delete_forever_outlined),
                            label: const Text('Empty trash'),
                          ),
                      ],
                    ),
                  ),
                ),
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

    // only medium has the modal rail: a resize out of it takes the rail
    // away without saying it closed
    if (wide || compact) _railOpen = false;
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
}
