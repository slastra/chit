import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../state/providers.dart';
import 'create.dart';
import 'masonry.dart';
import 'note_card.dart';

enum Shelf {
  notes('Notes', Icons.lightbulb_outline, Icons.lightbulb),
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
  String _query = '';
  final _scaffold = GlobalKey<ScaffoldState>();

  List<Note> _shown(Library lib) {
    final q = _query.trim().toLowerCase();
    bool hit(Note n) =>
        q.isEmpty ||
        n.label.toLowerCase().contains(q) ||
        n.body.toLowerCase().contains(q) ||
        (lib.items[n.id] ?? const []).any((i) => i.text.toLowerCase().contains(q));
    bool onShelf(Note n) {
      final st = lib.stateOf(n.id);
      return switch (_shelf) {
        Shelf.trash => n.trashed.isNotEmpty,
        Shelf.archive => st.archived && n.trashed.isEmpty,
        Shelf.notes => !st.archived && n.trashed.isEmpty,
      };
    }

    return lib.notes.where((n) => onShelf(n) && hit(n)).toList()..sort((a, b) => b.updated.compareTo(a.updated));
  }

  void _pick(Shelf s) => setState(() => _shelf = s);

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
    final pinned = _shelf == Shelf.notes ? shown.where((n) => lib.stateOf(n.id).pinned).toList() : <Note>[];
    final others = shown.where((n) => !pinned.contains(n)).toList();
    final wide = isExpanded(context);
    final theme = Theme.of(context);
    final firstSync = lib.notes.isEmpty && status?.phase != SyncPhase.online && status?.phase != SyncPhase.offline;
    final margin = wide ? 24.0 : 16.0;

    Widget grid(List<Note> notes) => Masonry(
      minColumnWidth: wide ? 240 : 160,
      spacing: 12,
      children: [for (final n in notes) NoteCard(key: ValueKey(n.id), note: n, library: lib)],
    );

    // Material 3 section headers: title-small, sentence case
    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
              hintText: _shelf == Shelf.notes ? 'Search your notes' : 'Search ${_shelf.label.toLowerCase()}',
              elevation: const WidgetStatePropertyAll(0),
              backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surfaceContainerHigh),
              leading: wide
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
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
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (pinned.isNotEmpty) ...[section('Pinned'), grid(pinned)],
                          if (pinned.isNotEmpty && others.isNotEmpty) section('Others') else const SizedBox(height: 8),
                          if (others.isNotEmpty) grid(others),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      key: _scaffold,
      drawer: wide ? null : _Drawer(shelf: _shelf, onPick: _pick),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _Drawer(shelf: _shelf, docked: true, onPick: _pick),
            Expanded(
              child: RefreshIndicator(onRefresh: _refresh, child: content),
            ),
          ],
        ),
      ),
      // Compact and medium: the FAB menu (Note, List, Link, Image). Expanded:
      // the split button at the foot of the docked drawer.
      floatingActionButton: !wide && _shelf == Shelf.notes ? const NewNoteFabMenu() : null,
    );
  }
}

/// The shelves. Docked beside the notes on an expanded screen, with the
/// new-note split button at its foot; slid out from the menu button
/// otherwise (the FAB menu creates notes there).
class _Drawer extends ConsumerWidget {
  const _Drawer({required this.shelf, required this.onPick, this.docked = false});
  final Shelf shelf;
  final bool docked;
  final ValueChanged<Shelf> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final drawer = NavigationDrawer(
      selectedIndex: shelf.index,
      backgroundColor: docked ? theme.colorScheme.surface : null,
      onDestinationSelected: (i) {
        onPick(Shelf.values[i]);
        if (!docked) Navigator.of(context).pop();
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 16, 16),
          child: Text('chit', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        ),
        for (final s in Shelf.values)
          NavigationDrawerDestination(icon: Icon(s.icon), selectedIcon: Icon(s.selectedIcon), label: Text(s.label)),
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
          };
    return Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Column(
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(
              color: scheme.primaryContainer,
              shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
            ),
            child: SizedBox.square(
              dimension: 120,
              child: Icon(searching ? Icons.search_off : shelf.icon, size: 48, color: scheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(height: 24),
          Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
