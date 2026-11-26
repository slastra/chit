import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/order.dart';
import '../core/protocol.dart';
import '../core/reminders.dart';
import '../core/roles.dart';
import '../data/local_files.dart' show clipboardImage;
import '../data/media.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../state/providers.dart';
import 'note_colors.dart';
import 'app.dart' show themeSpecProvider;
import 'attachments.dart';
import 'check_motion.dart';
import '../notifications.dart';
import 'create.dart' show newNoteDefaults;
import 'labels_ui.dart';
import 'reminder_picker.dart';
import 'share_sheet.dart';
import 'feedback.dart';
import 'theme.dart';

/// One note, open or new. Edits save as you pause (and work offline). A new
/// note only exists once something is typed; leaving one empty discards it,
/// as Keep does. The page wears the note's color: its whole scheme comes
/// from that hue.
class NotePage extends ConsumerStatefulWidget {
  const NotePage({
    super.key,
    this.noteId,
    this.list = false,
    this.inDialog = false,
    this.initialTitle = '',
    this.initialBody = '',
  });

  final String? noteId;

  /// Shown as a dialog over the board (expanded windows): an elevated
  /// surface, and a close button instead of back.
  final bool inDialog;

  /// For a new note: start as a checklist.
  final bool list;

  /// For a new note: content it starts with (a link, something shared in).
  /// A prefilled note is saved as soon as it opens, so closing it without
  /// an edit keeps it.
  final String initialTitle;
  final String initialBody;

  @override
  ConsumerState<NotePage> createState() => _NotePageState();
}

class _NotePageState extends ConsumerState<NotePage> {
  late final String _id = widget.noteId ?? randomId();
  late bool _exists = widget.noteId != null;

  /// A new note's label and reminder from the shelf it was made on, sent
  /// with its first edit.
  late final _defaults = widget.noteId == null ? newNoteDefaults.value : (label: null, remind: false);
  late final DateTime? _startReminder = _defaults.remind ? reminderPresets(DateTime.now()).first.at : null;
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

  // Kept from the last build: dispose() may not use ref (the element is
  // already unmounting), and it still has to send the last edits.
  SyncEngine? _engine;
  Library? _library;

  bool _dropping = false;

  /// Whether this person may change the note's content (not a viewer).
  bool _editable = true;
  late final _checkOff = CheckOff(() {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.noteId == null && (widget.initialTitle.isNotEmpty || widget.initialBody.isNotEmpty)) {
      _title.text = widget.initialTitle;
      _body.text = widget.initialBody;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _edit(
          () => [
            if (widget.initialTitle.isNotEmpty) _op(Collections.notes, _id, 'title', widget.initialTitle),
            if (widget.initialBody.isNotEmpty) _op(Collections.notes, _id, 'body', widget.initialBody),
          ],
        );
        _bodyFocus.requestFocus();
      });
    } else if (!_exists && !_listWhileNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bodyFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _checkOff.flush();
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
      if (_defaults.label case final label?) ops.add(_op(Collections.noteState, _id, 'labels', [label]));
      if (_startReminder case final at?) {
        ops.add(_op(Collections.noteState, _id, 'reminder', reminderWire(at)));
        ops.add(_op(Collections.noteState, _id, 'reminder_done', false));
      }
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
    final lib = _library;
    final items = lib?.items[_id] ?? const <Item>[];
    final empty =
        _title.text.trim().isEmpty &&
        _body.text.trim().isEmpty &&
        items.every((i) => i.text.trim().isEmpty) &&
        (lib?.attachments[_id]?.isEmpty ?? true);
    if (empty && widget.noteId == null) _edit(() => [_op(Collections.notes, _id, 'deleted', true)]);
  }

  /// An Undo for a snackbar. It runs after this page has closed, so it holds
  /// the engine itself rather than this page's (by then disposed) ref.
  VoidCallback _undo(String collection, String field, Object? value) {
    final engine = _engine;
    final id = _id;
    return () => engine?.edit([engine.op(collection, id, field, value)]);
  }

  /// Opens the label picker on this note (making the note first, if new).
  void _labelNote() {
    if (!_exists) _edit(() => const []);
    unawaited(showLabelPicker(context, [_id]));
  }

  void _setNote(String field, Object? value) => _edit(() => [_op(Collections.notes, _id, field, value)]);
  void _setState(String field, Object? value) => _edit(() => [_op(Collections.noteState, _id, field, value)]);

  /// Sets the reminder (and makes it pending again), or clears it. The
  /// first one set is when the phone asks to notify.
  void _remind(DateTime? at) {
    _edit(
      () => [
        _op(Collections.noteState, _id, 'reminder', at == null ? '' : reminderWire(at)),
        _op(Collections.noteState, _id, 'reminder_done', false),
      ],
    );
    if (at != null) unawaited(askNotificationPermission());
  }

  // ---- files -----------------------------------------------------------------

  /// Attaches files to this note, creating it first if it is new.
  Future<void> _attach(List<NewFile> picked) async {
    if (picked.isEmpty) return;
    _edit(() => []);
    await attachTo(context, _id, picked);
  }

  Future<void> _add(AddSource source) async {
    final picked = await pickFrom(context, source);
    if (mounted) await _attach(picked);
  }

  /// Ctrl+V with an image on the clipboard attaches it. The text fields
  /// still paste text as usual; an image comes through only when the
  /// clipboard has no plain text to offer.
  bool _onKey(KeyEvent e) {
    final paste =
        e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed);
    if (paste && _editable && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      unawaited(() async {
        final img = await clipboardImage();
        if (img != null && mounted) {
          await _attach([(name: img.name, size: img.bytes.length, path: null, bytes: img.bytes)]);
        }
      }());
    }
    return false;
  }

  void _removeFile(Attachment a) {
    if (a.pending) {
      unawaited(ref.read(replicaProvider).dropUpload(a.id));
      return;
    }
    final engine = _engine;
    if (engine == null) return;
    unawaited(engine.edit([engine.op(Collections.attachments, a.id, 'deleted', true)]));
    showUndo('File removed', () => engine.edit([engine.op(Collections.attachments, a.id, 'deleted', false)]));
  }

  /// A picture or file a keyboard inserts (Android's image keyboards and
  /// clipboard suggestions).
  late final _insertion = ContentInsertionConfiguration(
    onContentInserted: (content) {
      final data = content.data;
      if (data == null) return;
      final ext = content.mimeType.split('/').last.replaceAll('jpeg', 'jpg');
      final name = content.uri.split('/').last.contains('.') ? content.uri.split('/').last : 'Inserted.$ext';
      unawaited(_attach([(name: name, size: data.length, path: null, bytes: data)]));
    },
  );

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
    _engine = ref.watch(engineProvider);
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    _library = lib;
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
    final attached = lib.attachments[_id] ?? const <Attachment>[];
    final images = attached.where((a) => a.isImage).toList();
    final others = attached.where((a) => !a.isImage).toList();
    final items = lib.items[_id] ?? const <Item>[];
    final open = items.where((i) => !i.checked).toList();
    final checked = items.where((i) => i.checked).toList();
    final state = lib.stateOf(_id);
    final owned = note == null || note.owner == me;
    final members = lib.members[_id] ?? const <Member>[];
    final role = note == null ? Role.owner : roleOf(note, members, me);
    final editable = _editable = canEdit(role);
    final shared = members.isNotEmpty || !owned;
    final reminder = !_exists ? _startReminder : (state.reminderDone ? null : reminderTime(state.reminder));
    final labels = _exists ? lib.labelsOf(_id) : lib.labels.where((l) => l.id == _defaults.label).toList();
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

    final appTheme = Theme.of(context);
    final spec = ref.watch(themeSpecProvider).value;
    final scheme = noteScheme(note?.color ?? '', appTheme.brightness);
    // Rebuilt whole (themeFor), never copied, so component themes such as
    // the app bar's follow the page's surface. In a dialog an uncolored note
    // sits on Material's dialog container; a colored one on its color.
    final theme = scheme != null
        ? themeFor(scheme.copyWith(surface: scheme.primaryContainer, onSurface: scheme.onPrimaryContainer), spec)
        : widget.inDialog
        ? themeFor(appTheme.colorScheme.copyWith(surface: appTheme.colorScheme.surfaceContainerHigh), spec)
        : appTheme;
    final text = theme.textTheme;

    // A row folds out of its list and into the other when checked or
    // unchecked here (check_motion.dart); a change from elsewhere just moves.
    Widget itemRow(Item it) => Fold(
      key: ValueKey('${it.id}/${it.checked}'),
      leaving: _checkOff.isLeaving(it.id),
      enter: _checkOff.takeArrival(it.id, it.checked),
      onGone: () => _checkOff.gone(it.id),
      child: _ItemRow(
        key: ValueKey(it.id),
        item: it,
        editable: editable,
        checked: _checkOff.showsChecked(it.id) ? !it.checked : it.checked,
        controller: _itemCtl(it),
        focusNode: _itemNode(it.id),
        onCheck: (v) => _checkOff.start(
          it.id,
          target: v,
          still: MediaQuery.disableAnimationsOf(context),
          commit: () => _edit(() => [_op(Collections.items, it.id, 'checked', v)]),
        ),
        onChanged: (v) => _later('item:${it.id}', () => _edit(() => [_op(Collections.items, it.id, 'text', v)])),
        onSubmitted: () => _addItem(items, after: it),
        onRemove: () => _edit(() => [_op(Collections.items, it.id, 'deleted', true)]),
      ),
    );

    void archive() {
      final was = state.archived;
      _setState('archived', !was);
      if (!was) {
        context.pop();
        showUndo('Note archived', _undo(Collections.noteState, 'archived', false));
      }
    }

    void trash() {
      if (trashed) {
        _setNote('trashed', '');
        return;
      }
      _setNote('trashed', DateTime.now().toUtc().toIso8601String());
      context.pop();
      showUndo('Note moved to trash', _undo(Collections.notes, 'trashed', ''));
    }

    // Deleting forever cannot be undone, so it asks first (Material's rule
    // for irreversible actions); everything else acts at once with Undo.
    Future<void> deleteForever() async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.delete_forever_outlined),
          title: const Text('Delete this note forever?'),
          content: const Text('It goes from every device, for everyone it is shared with.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        ),
      );
      if (ok ?? false) {
        _setNote('deleted', true);
        // the State's own context, which `mounted` speaks for
        if (mounted) this.context.pop();
      }
    }

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          leading: widget.inDialog
              ? IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => context.pop())
              : null,
          actions: [
            // the owner shares; anyone it is shared with sees with whom
            if (_exists && note != null && (owned || shared))
              IconButton(
                tooltip: owned ? (shared ? 'Shared: change who' : 'Share') : 'Shared with you',
                icon: Icon(shared ? Icons.group_outlined : Icons.person_add_alt_outlined),
                onPressed: () => showShareSheet(context, _id),
              ),
            ReminderButton(current: reminder, onSet: _remind, onClear: () => _remind(null)),
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
              onPressed: _exists ? archive : null,
            ),
            MenuAnchor(
              builder: (context, ctl, _) => IconButton(
                tooltip: 'More options',
                icon: const Icon(Icons.more_vert),
                onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
              ),
              menuChildren: [
                // labels are the reader's own, viewers' too
                if (!trashed)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.label_outline),
                    onPressed: _labelNote,
                    child: Text(labels.isEmpty ? 'Add label' : 'Change labels'),
                  ),
                if (owned && _exists)
                  MenuItemButton(
                    leadingIcon: Icon(trashed ? Icons.restore_from_trash_outlined : Icons.delete_outline),
                    onPressed: trash,
                    child: Text(trashed ? 'Restore' : 'Delete'),
                  ),
                if (owned && trashed)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.delete_forever_outlined),
                    onPressed: deleteForever,
                    child: const Text('Delete forever'),
                  ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: DropTarget(
          onDragEntered: (_) => setState(() => _dropping = true),
          enable: editable,
          onDragExited: (_) => setState(() => _dropping = false),
          onDragDone: (d) async {
            setState(() => _dropping = false);
            final picked = <NewFile>[
              for (final f in d.files)
                (name: f.name, size: await f.length(), path: f.path.isEmpty ? null : f.path, bytes: null),
            ];
            await _attach(picked);
          },
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // images first, as Keep shows them
                          if (images.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ClipRRect(
                                // the card's corner, from the theme's shape scale
                                borderRadius:
                                    (theme.cardTheme.shape as RoundedRectangleBorder?)?.borderRadius.resolve(
                                      Directionality.of(context),
                                    ) ??
                                    BorderRadius.circular(12),
                                child: NoteImages(images: images),
                              ),
                            ),
                          TextField(
                            contentInsertionConfiguration: _insertion,
                            controller: _title,
                            focusNode: _titleFocus,
                            readOnly: !editable,
                            style: text.titleLarge,
                            decoration: const InputDecoration(hintText: 'Title', border: InputBorder.none),
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.sentences,
                            onChanged: (v) => _later('title', () => _setNote('title', v)),
                            onSubmitted: (_) => isList
                                ? (open.isEmpty ? _addItem(items) : _itemNode(open.first.id).requestFocus())
                                : _bodyFocus.requestFocus(),
                          ),
                          if (!isList)
                            TextField(
                              controller: _body,
                              focusNode: _bodyFocus,
                              readOnly: !editable,
                              style: text.bodyLarge,
                              decoration: const InputDecoration(hintText: 'Note', border: InputBorder.none),
                              maxLines: null,
                              minLines: 6,
                              keyboardType: TextInputType.multiline,
                              textCapitalization: TextCapitalization.sentences,
                              onChanged: (v) => _later('body', () => _setNote('body', v)),
                              contentInsertionConfiguration: _insertion,
                            ),
                          if (isList) ...[
                            for (final it in open) itemRow(it),
                            if (editable)
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
                                leading: AnimatedRotation(
                                  turns: _showChecked ? 0 : -0.25,
                                  duration: const Duration(milliseconds: 200),
                                  child: const Icon(Icons.expand_more),
                                ),
                                title: Text('${checked.length} checked item${checked.length == 1 ? '' : 's'}'),
                                onTap: () => setState(() => _showChecked = !_showChecked),
                              ),
                              if (_showChecked)
                                for (final it in checked) itemRow(it),
                            ],
                          ],
                          // the reminder and labels, under the text, as input
                          // chips: tap to change, x to remove
                          if (reminder != null || labels.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (reminder != null)
                                    InputChip(
                                      avatar: const Icon(Icons.alarm),
                                      label: Text(reminderLabel(reminder)),
                                      onPressed: () => showReminderSheet(
                                        context,
                                        current: reminder,
                                        onSet: _remind,
                                        onClear: () => _remind(null),
                                      ),
                                      deleteButtonTooltipMessage: 'Remove reminder',
                                      onDeleted: () => _remind(null),
                                    ),
                                  for (final l in labels)
                                    InputChip(
                                      label: Text(l.name),
                                      onPressed: _labelNote,
                                      deleteButtonTooltipMessage: 'Remove label',
                                      onDeleted: () => _edit(
                                        () => [
                                          _op(Collections.noteState, _id, 'labels', [
                                            for (final x in labels)
                                              if (x.id != l.id) x.id,
                                          ]),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          // other files below the text, each a row
                          if (others.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            for (final a in others)
                              FileRow(
                                key: ValueKey(a.id),
                                attachment: a,
                                onRemove: editable ? () => _removeFile(a) : null,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              // a drop lands on the whole note: say so while files hover
              if (_dropping)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: theme.colorScheme.primary, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Drop to attach',
                        style: text.titleMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: _NoteBar(
          isList: isList,
          editable: editable,
          inDialog: widget.inDialog,
          color: note?.color ?? '',
          edited: note?.updated ?? '',
          onToggleList: () => _convert(note, items),
          onColor: (c) => _setNote('color', c),
          onAdd: _add,
        ),
      ),
    );
  }
}

/// A checklist row. The remove button shows on the row being edited or
/// pointed at, not on every row at once.
class _ItemRow extends StatefulWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.editable,
    required this.checked,
    required this.controller,
    required this.focusNode,
    required this.onCheck,
    required this.onChanged,
    required this.onSubmitted,
    required this.onRemove,
  });

  final Item item;

  /// A viewer sees the list but cannot change it.
  final bool editable;

  /// What the row shows: the item's state, or where it is headed while it
  /// plays its check-off.
  final bool checked;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<bool> onCheck;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final VoidCallback onRemove;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final it = widget.item;
    final active = _hover || widget.focusNode.hasFocus;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: EdgeInsets.only(left: 4.0 + it.indent * 28),
        child: Row(
          children: [
            Checkbox(value: widget.checked, onChanged: widget.editable ? (v) => widget.onCheck(v ?? false) : null),
            Expanded(
              child: TextField(
                readOnly: !widget.editable,
                controller: widget.controller,
                focusNode: widget.focusNode,
                style: theme.textTheme.bodyLarge?.copyWith(
                  decoration: widget.checked ? TextDecoration.lineThrough : null,
                  color: widget.checked ? theme.colorScheme.onSurfaceVariant : null,
                ),
                decoration: const InputDecoration(hintText: 'List item', isDense: true, border: InputBorder.none),
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onSubmitted(),
              ),
            ),
            AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: IconButton(
                tooltip: 'Remove ${it.text}',
                icon: const Icon(Icons.close),
                onPressed: active && widget.editable ? widget.onRemove : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Along the bottom, as Material 3 Expressive's docked toolbar (64dp,
/// surface container, 16dp ends): switch note and checklist, the color
/// choice, and when the note was last edited.
class _NoteBar extends StatelessWidget {
  const _NoteBar({
    required this.isList,
    required this.editable,
    required this.inDialog,
    required this.color,
    required this.edited,
    required this.onToggleList,
    required this.onColor,
    required this.onAdd,
  });
  final bool isList;

  /// A viewer gets no content tools, only when it was last edited.
  final bool editable;
  final bool inDialog;
  final String color;
  final String edited;
  final VoidCallback onToggleList;
  final ValueChanged<String> onColor;
  final ValueChanged<AddSource> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = DateTime.tryParse(edited.replaceFirst(' ', 'T'))?.toLocal();
    return BottomAppBar(
      // inside a dialog it sits on the dialog's own container, as a dialog's
      // actions do, rather than a darker band across its foot
      color: inDialog ? theme.colorScheme.surface : theme.colorScheme.surfaceContainer,
      elevation: 0,
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (editable) ...[
            IconButton(
              tooltip: isList ? 'Turn into a note' : 'Turn into a checklist',
              isSelected: isList,
              icon: const Icon(Icons.check_box_outlined),
              selectedIcon: const Icon(Icons.check_box),
              onPressed: onToggleList,
            ),
            ColorButton(current: color, onPick: onColor),
            AddButton(onPick: onAdd),
          ],
          const Spacer(),
          if (when != null)
            Text(
              'Edited ${_when(context, when)}',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  static String _when(BuildContext context, DateTime d) {
    final time = TimeOfDay.fromDateTime(d).format(context);
    return DateUtils.isSameDay(d, DateTime.now())
        ? time
        : '${MaterialLocalizations.of(context).formatShortMonthDay(d)}, $time';
  }
}
