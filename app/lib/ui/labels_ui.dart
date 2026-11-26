import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/labels.dart';
import '../core/protocol.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'feedback.dart';
import 'home_page.dart' show isExpanded;

/// Creates a label called [name] (or finds the one already called that) and
/// returns its id; null when the name is empty or nobody is signed in.
String? ensureLabel(WidgetRef ref, String name) {
  final clean = labelName(name);
  final engine = ref.read(engineProvider);
  if (clean.isEmpty || engine == null) return null;
  final lib = ref.read(libraryProvider).value ?? Library.empty;
  if (labelNamed(lib.labels, clean) case final existing?) return existing.id;
  final id = randomId();
  unawaited(engine.edit([engine.op(Collections.labels, id, 'name', clean)]));
  return id;
}

/// Turns [label] on or off for [notes], sending only the notes that change.
void setLabel(WidgetRef ref, Iterable<String> notes, String label, {required bool on}) {
  final engine = ref.read(engineProvider);
  final lib = ref.read(libraryProvider).value;
  if (engine == null || lib == null) return;
  final changes = toggleLabel({for (final n in notes) n: lib.stateOf(n).labels}, label, on: on);
  if (changes.isEmpty) return;
  unawaited(
    engine.edit([
      for (final MapEntry(key: note, value: ids) in changes.entries)
        engine.op(Collections.noteState, note, 'labels', ids),
    ]),
  );
}

/// Labels [notes]: a checkbox per label (a dash where only some of the
/// notes have it), a filter, and creating a label from what was typed. A
/// dialog on expanded windows, a bottom sheet on compact ones. Each change
/// applies as it is made.
Future<void> showLabelPicker(BuildContext context, List<String> notes) {
  final picker = _LabelPicker(notes: notes);
  if (isExpanded(context)) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400, maxHeight: 560), child: picker),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: picker,
      ),
    ),
  );
}

class _LabelPicker extends ConsumerStatefulWidget {
  const _LabelPicker({required this.notes});
  final List<String> notes;

  @override
  ConsumerState<_LabelPicker> createState() => _LabelPickerState();
}

class _LabelPickerState extends ConsumerState<_LabelPicker> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _create() {
    final id = ensureLabel(ref, _filter.text);
    if (id == null) return;
    // the label's record and the notes' lists go out together, in order
    setLabel(ref, widget.notes, id, on: true);
    _filter.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final typed = labelName(_filter.text);
    final q = typed.toLowerCase();
    final shown = [
      for (final l in lib.labels)
        if (q.isEmpty || l.name.toLowerCase().contains(q)) l,
    ];
    final canCreate = typed.isNotEmpty && labelNamed(lib.labels, typed) == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Text(widget.notes.length == 1 ? 'Label note' : 'Label notes', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _filter,
            autofocus: isExpanded(context),
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Enter label name',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            // Enter creates what was typed, and stays for the next
            onEditingComplete: () => canCreate ? _create() : null,
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (final l in shown)
                CheckboxListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  tristate: true,
                  value: labelState([for (final n in widget.notes) lib.stateOf(n).labels], l.id),
                  // a dash (some of the notes) checks it for all of them
                  onChanged: (v) => setLabel(
                    ref,
                    widget.notes,
                    l.id,
                    on: labelState([for (final n in widget.notes) lib.stateOf(n).labels], l.id) != true,
                  ),
                  title: Text(l.name),
                ),
              if (canCreate) ListTile(leading: const Icon(Icons.add), title: Text('Create "$typed"'), onTap: _create),
              if (shown.isEmpty && !canCreate)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No labels yet. Type a name to make one.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
        // a dialog ends with its actions; a sheet is dismissed by its handle
        if (isExpanded(context))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ),
          ),
      ],
    );
  }
}

/// Creating, renaming and deleting labels: a basic dialog on expanded
/// windows, a full-screen one on compact ones (Material's pattern for a
/// dialog with a form).
Future<void> showEditLabels(BuildContext context) {
  if (isExpanded(context)) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
          child: const _EditLabels(fullscreen: false),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => const Dialog.fullscreen(child: _EditLabels(fullscreen: true)),
  );
}

class _EditLabels extends ConsumerStatefulWidget {
  const _EditLabels({required this.fullscreen});
  final bool fullscreen;

  @override
  ConsumerState<_EditLabels> createState() => _EditLabelsState();
}

class _EditLabelsState extends ConsumerState<_EditLabels> {
  final _new = TextEditingController();

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  void _create() {
    final lib = ref.read(libraryProvider).value ?? Library.empty;
    final name = labelName(_new.text);
    if (name.isEmpty) return;
    if (labelNamed(lib.labels, name) != null) {
      showMessage('There is already a label called $name');
      return;
    }
    ensureLabel(ref, name);
    _new.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final list = ListView(
      shrinkWrap: !widget.fullscreen,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // a new label: the field, and a check to keep it
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            controller: _new,
            autofocus: lib.labels.isEmpty,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Create new label',
              prefixIcon: const Icon(Icons.add),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(tooltip: 'Create label', icon: const Icon(Icons.check), onPressed: _create),
            ),
            // Enter keeps the field, to make several in a row
            onEditingComplete: _create,
          ),
        ),
        const SizedBox(height: 8),
        for (final l in lib.labels) _LabelRow(key: ValueKey(l.id), label: l),
      ],
    );
    if (widget.fullscreen) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          title: const Text('Edit labels'),
        ),
        body: list,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Text('Edit labels', style: theme.textTheme.headlineSmall),
        ),
        Flexible(child: list),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ),
        ),
      ],
    );
  }
}

/// One label, renamed in place (kept when the field is left or submitted)
/// and deleted after asking.
class _LabelRow extends ConsumerStatefulWidget {
  const _LabelRow({super.key, required this.label});
  final Label label;

  @override
  ConsumerState<_LabelRow> createState() => _LabelRowState();
}

class _LabelRowState extends ConsumerState<_LabelRow> {
  late final _name = TextEditingController(text: widget.label.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _rename();
    });
  }

  @override
  void didUpdateWidget(_LabelRow old) {
    super.didUpdateWidget(old);
    // renamed elsewhere, and not being edited here
    if (!_focus.hasFocus && widget.label.name != _name.text) _name.text = widget.label.name;
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rename() {
    final name = labelName(_name.text);
    final l = widget.label;
    if (name == l.name) return;
    final lib = ref.read(libraryProvider).value ?? Library.empty;
    final clash = labelNamed(lib.labels, name);
    if (name.isEmpty || (clash != null && clash.id != l.id)) {
      if (name.isNotEmpty) showMessage('There is already a label called $name');
      _name.text = l.name;
      return;
    }
    final engine = ref.read(engineProvider);
    unawaited(engine?.edit([engine.op(Collections.labels, l.id, 'name', name)]));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete label?'),
        content: Text('"${widget.label.name}" will be removed from all your notes. The notes themselves stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final engine = ref.read(engineProvider);
    unawaited(engine?.edit([engine.op(Collections.labels, widget.label.id, 'deleted', true)]));
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.label_outline),
    title: TextField(
      controller: _name,
      focusNode: _focus,
      decoration: const InputDecoration(border: InputBorder.none, isDense: true),
      onSubmitted: (_) => _rename(),
    ),
    trailing: IconButton(tooltip: 'Delete label', icon: const Icon(Icons.delete_outline), onPressed: _delete),
  );
}
