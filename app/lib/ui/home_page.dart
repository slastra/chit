import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../state/providers.dart';
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

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final shown = _shown(lib);
    final pinned = _shelf == Shelf.notes ? shown.where((n) => lib.stateOf(n.id).pinned).toList() : <Note>[];
    final others = shown.where((n) => !pinned.contains(n)).toList();
    // Material's expanded size class: the drawer docks beside the notes
    final wide = MediaQuery.sizeOf(context).width >= 840;

    Widget grid(List<Note> notes) => Masonry(
      minColumnWidth: wide ? 240 : 160,
      spacing: 12,
      children: [for (final n in notes) NoteCard(key: ValueKey(n.id), note: n, library: lib)],
    );

    final theme = Theme.of(context);
    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2),
      ),
    );

    return Scaffold(
      key: _scaffold,
      drawer: wide ? null : _Drawer(shelf: _shelf, onPick: (s) => setState(() => _shelf = s)),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _Drawer(shelf: _shelf, docked: true, onPick: (s) => setState(() => _shelf = s)),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverAppBar(
                    floating: true,
                    toolbarHeight: 72,
                    titleSpacing: 12,
                    automaticallyImplyLeading: false,
                    centerTitle: true,
                    title: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: SearchBar(
                        hintText: _shelf == Shelf.notes ? 'Search notes' : 'Search ${_shelf.label.toLowerCase()}',
                        elevation: const WidgetStatePropertyAll(0),
                        leading: wide
                            ? const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.search))
                            : IconButton(
                                icon: const Icon(Icons.menu),
                                tooltip: 'Menu',
                                onPressed: () => _scaffold.currentState?.openDrawer(),
                              ),
                        trailing: const [_SyncMark()],
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                    // centered and capped, so a very wide screen does not stretch
                    // the grid edge to edge
                    sliver: SliverToBoxAdapter(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1600),
                          child: shown.isEmpty
                              ? _Empty(shelf: _shelf, searching: _query.trim().isNotEmpty)
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (pinned.isNotEmpty) ...[section('Pinned'), grid(pinned)],
                                    if (pinned.isNotEmpty && others.isNotEmpty)
                                      section('Others')
                                    else
                                      const SizedBox(height: 8),
                                    if (others.isNotEmpty) grid(others),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _shelf == Shelf.notes
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'list',
                  tooltip: 'New list',
                  onPressed: () => context.push('/note/new?list=1'),
                  child: const Icon(Icons.checklist),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'note',
                  onPressed: () => context.push('/note/new'),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Note'),
                ),
              ],
            )
          : null,
    );
  }
}

/// The shelves and the account. Docked beside the notes on a wide screen
/// (a standard drawer), slid out from the menu button otherwise.
class _Drawer extends ConsumerWidget {
  const _Drawer({required this.shelf, required this.onPick, this.docked = false});
  final Shelf shelf;
  final bool docked;
  final ValueChanged<Shelf> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    return NavigationDrawer(
      selectedIndex: shelf.index,
      onDestinationSelected: (i) {
        onPick(Shelf.values[i]);
        if (!docked) Navigator.of(context).pop();
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 12),
          child: Text('chit', style: Theme.of(context).textTheme.titleLarge),
        ),
        for (final s in Shelf.values)
          NavigationDrawerDestination(icon: Icon(s.icon), selectedIcon: Icon(s.selectedIcon), label: Text(s.label)),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 12), child: Divider()),
        if (session != null)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 28),
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(session.user.display),
            subtitle: Text(Uri.parse(session.server).host),
          ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 28),
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: () => ref.read(sessionProvider.notifier).signOut(),
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
        ? 'No notes match.'
        : switch (shelf) {
            Shelf.notes => 'Notes you add appear here',
            Shelf.archive => 'Archived notes appear here',
            Shelf.trash => 'The trash is empty',
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
