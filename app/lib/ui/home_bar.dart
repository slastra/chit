part of 'home_page.dart';

// The search bar's company: the filter chips under it, the account and its
// menu, and the sync mark.

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
