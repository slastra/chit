import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/order.dart';
import '../core/protocol.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../state/providers.dart';
import 'note_colors.dart';
import 'app.dart' show themeSpecProvider;
import 'theme.dart';

/// One note, open or new. Edits save as you pause (and work offline). A new
/// note only exists once something is typed; leaving one empty discards it,
/// as Keep does. The page wears the note's color: its whole scheme comes
/// from that hue.
class NotePage extends ConsumerStatefulWidget {
  const NotePage({super.key, this.noteId, this.list = false});

  final String? noteId;

  /// For a new note: start as a checklist.
  final bool list;

  @override
  ConsumerState<NotePage> createState() => _NotePageState();
}

class _NotePageState extends ConsumerState<NotePage> {
  late final String _id = widget.noteId ?? randomId();
  late bool _exists = widget.noteId != null;
  late bool _listWhileNew = widget.list;

  final _title = TextEditingController();
  final _body = TextEditingController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();
  final _items = <String, TextEditingController>{};
  final _itemFocus = <String, FocusNode>{};
  final _timers = <String, Timer>{};
  bool _showChecked = true;
  bool _loaded = false;
  String? _focusNext;

  SyncEngine? get _engine => ref.read(engineProvider);

  @override
  void initState() {
    super.initState();
    if (!_exists && !_listWhileNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bodyFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _flushAll();
    _discardIfEmpty();
    _title.dispose();
    _body.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    for (final c in _items.values) {
      c.dispose();
    }
    for (final f in _itemFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  // ---- writing -------------------------------------------------------------

  Op _op(String collection, String id, String field, Object? value) => _engine!.op(collection, id, field, value);

  /// Sends edits, creating the note first if this is its first one.
  void _edit(List<Op> Function() build) {
    final engine = _engine;
    if (engine == null) return;
    final ops = <Op>[];
    if (!_exists) {
      ops.add(_op(Collections.notes, _id, 'kind', _listWhileNew ? 'list' : 'text'));
      _exists = true;
    }
    ops.addAll(build());
    unawaited(engine.edit(ops));
  }

  void _debounce(String key, VoidCallback send) {
    _timers[key]?.cancel();
    _timers[key] = Timer(const Duration(milliseconds: 500), () {
      _timers.remove(key);
      send();
    });
  }

  final _pendingSends = <String, VoidCallback>{};
  void _later(String key, VoidCallback send) {
    _pendingSends[key] = send;
    _debounce(key, () => _pendingSends.remove(key)?.call());
  }

  void _flushAll() {
    for (final send in _pendingSends.values.toList()) {
      send();
    }
    _pendingSends.clear();
  }

  void _discardIfEmpty() {
    if (!_exists) return;
    final lib = ref.read(libraryProvider).value;
    final items = lib?.items[_id] ?? const <Item>[];
    final empty =
        _title.text.trim().isEmpty &&
        _body.text.trim().isEmpty &&
        items.every((i) => i.text.trim().isEmpty) &&
        (lib?.attachments[_id]?.isEmpty ?? true);
    if (empty && widget.noteId == null) _edit(() => [_op(Collections.notes, _id, 'deleted', true)]);
  }

  void _setNote(String field, Object? value) => _edit(() => [_op(Collections.notes, _id, field, value)]);
  void _setState(String field, Object? value) => _edit(() => [_op(Collections.noteState, _id, field, value)]);

  // ---- checklist -------------------------------------------------------------

  TextEditingController _itemCtl(Item it) => _items.putIfAbsent(it.id, () => TextEditingController(text: it.text));
  FocusNode _itemNode(String id) => _itemFocus.putIfAbsent(id, FocusNode.new);

  void _addItem(List<Item> items, {Item? after}) {
    final open = items.where((i) => !i.checked).toList();
    final prev = after?.order ?? (open.isEmpty ? '' : open.last.order);
    final next = after == null
        ? ''
        : (() {
            final i = items.indexWhere((x) => x.id == after.id);
            return i + 1 < items.length ? items[i + 1].order : '';
          })();
    final id = randomId();
    _focusNext = id;
    _edit(
      () => [
        _op(Collections.items, id, 'note', _id),
        _op(Collections.items, id, 'text', ''),
        _op(Collections.items, id, 'order', orderBetween(prev, next == prev ? '' : next)),
      ],
    );
  }

  /// A checklist becomes text (one line per item, open ones first) or text
  /// becomes a checklist (one item per line).
  void _convert(Note? note, List<Item> items) {
    if (!_exists) {
      setState(() => _listWhileNew = !_listWhileNew);
      return;
    }
    if (note?.isList ?? false) {
      final lines = [...items.where((i) => !i.checked), ...items.where((i) => i.checked)].map((i) => i.text);
      _edit(
        () => [
          for (final i in items) _op(Collections.items, i.id, 'deleted', true),
          _op(Collections.notes, _id, 'body', lines.join('\n')),
          _op(Collections.notes, _id, 'kind', 'text'),
        ],
      );
    } else {
      var last = '';
      _edit(
        () => [
          for (final line in _body.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty))
            ...(() {
              final id = randomId();
              last = orderAfter(last);
              return [
                _op(Collections.items, id, 'note', _id),
                _op(Collections.items, id, 'text', line),
                _op(Collections.items, id, 'order', last),
              ];
            })(),
          _op(Collections.notes, _id, 'body', ''),
          _op(Collections.notes, _id, 'kind', 'list'),
        ],
      );
    }
  }

  // ---- view ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final note = lib.notes.where((n) => n.id == _id).firstOrNull;
    final me = ref.watch(sessionProvider).value?.user.id ?? '';

    // An open note that went away (deleted elsewhere, access revoked).
    if (widget.noteId != null && note == null && ref.watch(libraryProvider).hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
    if (note != null && !_loaded) {
      _loaded = true;
      _title.text = note.title;
      _body.text = note.body;
    } else if (note != null) {
      if (!_titleFocus.hasFocus && !_pendingSends.containsKey('title') && _title.text != note.title) {
        _title.text = note.title;
      }
      if (!_bodyFocus.hasFocus && !_pendingSends.containsKey('body') && _body.text != note.body) {
        _body.text = note.body;
      }
    }

    final isList = note?.isList ?? _listWhileNew;
    final items = lib.items[_id] ?? const <Item>[];
    final open = items.where((i) => !i.checked).toList();
    final checked = items.where((i) => i.checked).toList();
    final state = lib.stateOf(_id);
    final owned = note == null || note.owner == me;
    final trashed = note?.trashed.isNotEmpty ?? false;

    for (final it in items) {
      final c = _itemCtl(it);
      if (!_itemNode(it.id).hasFocus && !_pendingSends.containsKey('item:${it.id}') && c.text != it.text) {
        c.text = it.text;
      }
    }
    if (_focusNext case final id? when items.any((i) => i.id == id)) {
      _focusNext = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _itemNode(id).requestFocus());
    }

    final base = Theme.of(context);
    final scheme = noteScheme(note?.color ?? '', base.brightness);
    final theme = scheme == null
        ? base
        : themeFor(
            scheme.copyWith(surface: scheme.primaryContainer, onSurface: scheme.onPrimaryContainer),
            ref.watch(themeSpecProvider).value,
          );
    final text = theme.textTheme;

    Widget itemRow(Item it) => Padding(
      key: ValueKey(it.id),
      padding: EdgeInsets.only(left: 8.0 + it.indent * 28),
      child: Row(
        children: [
          Checkbox(
            value: it.checked,
            onChanged: (v) => _edit(() => [_op(Collections.items, it.id, 'checked', v ?? false)]),
          ),
          Expanded(
            child: TextField(
              controller: _itemCtl(it),
              focusNode: _itemNode(it.id),
              style: text.bodyLarge?.copyWith(
                decoration: it.checked ? TextDecoration.lineThrough : null,
                color: it.checked ? theme.colorScheme.onSurfaceVariant : null,
              ),
              decoration: const InputDecoration(hintText: 'List item', isDense: true),
              textInputAction: TextInputAction.next,
              onChanged: (v) => _later('item:${it.id}', () => _edit(() => [_op(Collections.items, it.id, 'text', v)])),
              onSubmitted: (_) => _addItem(items, after: it),
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close),
            onPressed: () => _edit(() => [_op(Collections.items, it.id, 'deleted', true)]),
          ),
        ],
      ),
    );

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          backgroundColor: theme.colorScheme.surface,
          actions: [
            IconButton(
              tooltip: state.pinned ? 'Unpin' : 'Pin',
              isSelected: state.pinned,
              icon: const Icon(Icons.push_pin_outlined),
              selectedIcon: const Icon(Icons.push_pin),
              onPressed: () => _setState('pinned', !state.pinned),
            ),
            IconButton(
              tooltip: state.archived ? 'Unarchive' : 'Archive',
              isSelected: state.archived,
              icon: const Icon(Icons.archive_outlined),
              selectedIcon: const Icon(Icons.unarchive_outlined),
              onPressed: _exists
                  ? () {
                      _setState('archived', !state.archived);
                      if (!state.archived) context.pop();
                    }
                  : null,
            ),
            MenuAnchor(
              builder: (context, ctl, _) => IconButton(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
              ),
              menuChildren: [
                MenuItemButton(
                  leadingIcon: Icon(isList ? Icons.notes : Icons.checklist),
                  onPressed: () => _convert(note, items),
                  child: Text(isList ? 'Turn into a note' : 'Turn into a checklist'),
                ),
                if (owned && _exists)
                  MenuItemButton(
                    leadingIcon: Icon(trashed ? Icons.restore_from_trash_outlined : Icons.delete_outline),
                    onPressed: () {
                      _setNote('trashed', trashed ? '' : DateTime.now().toUtc().toIso8601String());
                      if (!trashed) context.pop();
                    },
                    child: Text(trashed ? 'Restore' : 'Move to trash'),
                  ),
                if (owned && trashed)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.delete_forever_outlined),
                    onPressed: () {
                      _setNote('deleted', true);
                      context.pop();
                    },
                    child: const Text('Delete forever'),
                  ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _title,
                      focusNode: _titleFocus,
                      style: text.headlineSmall,
                      decoration: const InputDecoration(hintText: 'Title'),
                      textInputAction: TextInputAction.next,
                      onChanged: (v) => _later('title', () => _setNote('title', v)),
                      onSubmitted: (_) => isList
                          ? (open.isEmpty ? _addItem(items) : _itemNode(open.first.id).requestFocus())
                          : _bodyFocus.requestFocus(),
                    ),
                    if (!isList)
                      TextField(
                        controller: _body,
                        focusNode: _bodyFocus,
                        style: text.bodyLarge,
                        decoration: const InputDecoration(hintText: 'Note'),
                        maxLines: null,
                        minLines: 6,
                        keyboardType: TextInputType.multiline,
                        onChanged: (v) => _later('body', () => _setNote('body', v)),
                      ),
                    if (isList) ...[
                      for (final it in open) itemRow(it),
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('List item'),
                        contentPadding: const EdgeInsets.only(left: 16),
                        onTap: () => _addItem(items),
                      ),
                      if (checked.isNotEmpty) ...[
                        const Divider(),
                        ListTile(
                          contentPadding: const EdgeInsets.only(left: 16),
                          leading: Icon(_showChecked ? Icons.expand_less : Icons.expand_more),
                          title: Text('${checked.length} checked item${checked.length == 1 ? '' : 's'}'),
                          onTap: () => setState(() => _showChecked = !_showChecked),
                        ),
                        if (_showChecked)
                          for (final it in checked) itemRow(it),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _ColorBar(
          current: note?.color ?? '',
          edited: note?.updated ?? '',
          onPick: (c) => _setNote('color', c),
        ),
      ),
    );
  }
}

/// The note's colors and when it was last edited, along the bottom.
class _ColorBar extends StatelessWidget {
  const _ColorBar({required this.current, required this.edited, required this.onPick});
  final String current;
  final String edited;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = DateTime.tryParse(edited.replaceFirst(' ', 'T'))?.toLocal();
    return BottomAppBar(
      color: theme.colorScheme.surface,
      height: 64,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 8,
                children: [
                  for (final name in ['', ...noteHues.keys])
                    _Swatch(name: name, selected: name == current, onTap: () => onPick(name)),
                ],
              ),
            ),
          ),
          if (when != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                'Edited ${TimeOfDay.fromDateTime(when).format(context)}',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.selected, required this.onTap});
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hue = noteHues[name];
    return Tooltip(
      message: name.isEmpty ? 'No color' : name,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: hue ?? theme.colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? theme.colorScheme.onSurface : theme.colorScheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: name.isEmpty
              ? Icon(Icons.format_color_reset_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }
}
