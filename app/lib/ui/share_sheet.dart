import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../core/roles.dart';
import '../data/api.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'feedback.dart';
import 'home_page.dart' show isExpanded;
import 'people.dart';
import 'expressive.dart';

/// Who a note is shared with, and (for its owner) adding people, changing
/// their role, and removing them: a dialog on expanded windows, a bottom
/// sheet on compact ones. Anyone it was shared with can leave it here.
Future<void> showShareSheet(BuildContext context, String noteId) {
  final sheet = _ShareSheet(noteId: noteId);
  return isExpanded(context)
      ? showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640), child: sheet),
          ),
        )
      : showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => SafeArea(child: sheet),
        );
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.noteId});
  final String noteId;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  final _busy = <String>{};

  /// Runs a server call for [who] (sharing is online only), saying so if it
  /// cannot reach the server.
  Future<void> _call(String who, Future<void> Function(ChitApi api) run) async {
    final api = ref.read(engineProvider)?.api;
    if (api == null) return;
    setState(() => _busy.add(who));
    try {
      await run(api);
    } on ApiError catch (e) {
      showMessage(e.message);
    } catch (_) {
      showMessage("Can't reach the server to change sharing");
    } finally {
      if (mounted) setState(() => _busy.remove(who));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final me = ref.watch(sessionProvider).value?.user.id ?? '';
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final note = lib.notes.where((n) => n.id == widget.noteId).firstOrNull;
    if (note == null) return const SizedBox.shrink();
    final members = lib.members[note.id] ?? const <Member>[];
    final role = roleOf(note, members, me);
    final owner = role == Role.owner;
    final onNote = {note.owner, ...members.map((m) => m.user)};
    final others = people.where((p) => !onNote.contains(p.id)).toList();
    String you(String id) => id == me ? ' (you)' : '';

    Widget busyOr(String id, Widget child) => _busy.contains(id) ? const LoadingIndicator(size: 32) : child;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Text(owner ? 'Share' : 'Shared with you', style: theme.textTheme.headlineSmall),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              SegmentedList(
                children: [
                  ListTile(
                    leading: PersonAvatar(id: note.owner),
                    title: Text('${nameOf(people, note.owner)}${you(note.owner)}'),
                    subtitle: const Text('Owner'),
                  ),
                  for (final m in members)
                    ListTile(
                      leading: PersonAvatar(id: m.user),
                      title: Text('${nameOf(people, m.user)}${you(m.user)}'),
                      subtitle: owner ? null : Text(m.role == 'viewer' ? 'Can view' : 'Can edit'),
                      trailing: !owner
                          ? null
                          : busyOr(
                              m.user,
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // the role: a text button with a menu, light in a list row
                                  MenuAnchor(
                                    builder: (context, menu, _) => TextButton.icon(
                                      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                                      icon: const Icon(Icons.arrow_drop_down),
                                      iconAlignment: IconAlignment.end,
                                      label: Text(m.role == 'viewer' ? 'Can view' : 'Can edit'),
                                    ),
                                    menuChildren: [
                                      for (final (r, label) in const [('editor', 'Can edit'), ('viewer', 'Can view')])
                                        MenuItemButton(
                                          leadingIcon: Icon(m.role == r ? Icons.check : null),
                                          onPressed: m.role == r
                                              ? null
                                              : () => unawaited(
                                                  _call(m.user, (api) => api.share(note.id, m.user, role: r)),
                                                ),
                                          child: Text(label),
                                        ),
                                    ],
                                  ),
                                  IconButton(
                                    tooltip: 'Remove ${nameOf(people, m.user)}',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => _call(m.user, (api) => api.unshare(note.id, m.user)),
                                  ),
                                ],
                              ),
                            ),
                    ),
                ],
              ),
              if (owner && others.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
                  child: Text(
                    'Add people',
                    style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                SegmentedList(
                  children: [
                    for (final p in others)
                      ListTile(
                        leading: PersonAvatar(id: p.id),
                        title: Text(p.display),
                        subtitle: p.name.isEmpty ? null : Text(p.email),
                        trailing: busyOr(
                          p.id,
                          FilledButton.tonal(
                            onPressed: () => _call(p.id, (api) => api.share(note.id, p.id)),
                            child: const Text('Add'),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              if (role == Role.editor || role == Role.viewer)
                TextButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Leave note'),
                  onPressed: () async {
                    await _call(me, (api) => api.unshare(note.id, me));
                    if (context.mounted) Navigator.of(context).pop();
                    if (context.mounted && context.canPop()) context.pop();
                  },
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
            ],
          ),
        ),
      ],
    );
  }
}
