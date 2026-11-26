import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// What a new note can start as. Image arrives with attachments.
enum NewKind {
  note('Note', Icons.edit_outlined),
  list('List', Icons.check_box_outlined),
  link('Link', Icons.link),
  image('Image', Icons.image_outlined, available: false);

  const NewKind(this.label, this.icon, {this.available = true});
  final String label;
  final IconData icon;
  final bool available;
}

/// Starts a new note of [kind].
Future<void> startNote(BuildContext context, NewKind kind) async {
  switch (kind) {
    case NewKind.note:
      await context.push('/note/new');
    case NewKind.list:
      await context.push('/note/new?list=1');
    case NewKind.link:
      final url = await _askLink(context);
      if (url == null || !context.mounted) return;
      final host = Uri.tryParse(url)?.host.replaceFirst(RegExp(r'^www\.'), '') ?? '';
      await context.push(Uri(path: '/note/new', queryParameters: {'title': host, 'text': url}).toString());
    case NewKind.image:
      break; // with attachments
  }
}

/// A link to save, offered from the clipboard when it holds one.
Future<String?> _askLink(BuildContext context) async {
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
  final looksLikeUrl = RegExp(r'^https?://\S+$').hasMatch(clip);
  if (!context.mounted) return null;
  final ctl = TextEditingController(text: looksLikeUrl ? clip : '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.link),
      title: const Text('Save a link'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'URL', hintText: 'https://', border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Save')),
      ],
    ),
  );
  ctl.dispose();
  final url = result?.trim() ?? '';
  if (url.isEmpty) return null;
  return url.contains('://') ? url : 'https://$url';
}

/// Material 3 Expressive split button: the main action, and beside it a
/// menu of the other ways to start. Two connected halves with a 2dp gap and
/// tight inner corners; while the menu is open the menu half turns fully
/// round and its arrow flips, as the spec draws it.
class NewNoteSplitButton extends StatefulWidget {
  const NewNoteSplitButton({super.key});

  @override
  State<NewNoteSplitButton> createState() => _NewNoteSplitButtonState();
}

class _NewNoteSplitButtonState extends State<NewNoteSplitButton> {
  final _menu = MenuController();
  bool _open = false;

  static const _outer = Radius.circular(28);
  static const _inner = Radius.circular(4);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      minimumSize: const Size(0, 56),
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
    );
    return Row(
      spacing: 2,
      children: [
        Expanded(
          child: FilledButton.icon(
            style: style.copyWith(
              shape: const WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(left: _outer, right: _inner),
                ),
              ),
            ),
            onPressed: () => startNote(context, NewKind.note),
            icon: Icon(NewKind.note.icon),
            label: const Text('New note'),
          ),
        ),
        MenuAnchor(
          controller: _menu,
          onOpen: () => setState(() => _open = true),
          onClose: () => setState(() => _open = false),
          alignmentOffset: const Offset(0, 4),
          menuChildren: [
            for (final kind in NewKind.values.where((k) => k != NewKind.note))
              MenuItemButton(
                leadingIcon: Icon(kind.icon),
                onPressed: kind.available ? () => startNote(context, kind) : null,
                child: Text(kind.available ? kind.label : '${kind.label} (soon)'),
              ),
          ],
          builder: (context, ctl, _) => AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutBack,
            child: FilledButton(
              style: style.copyWith(
                minimumSize: const WidgetStatePropertyAll(Size(48, 56)),
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
                shape: WidgetStatePropertyAll(
                  _open
                      ? const StadiumBorder()
                      : const RoundedRectangleBorder(
                          borderRadius: BorderRadius.horizontal(left: _inner, right: _outer),
                        ),
                ),
              ),
              onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
              child: AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.keyboard_arrow_down, semanticLabel: _open ? 'Close menu' : 'More ways to start'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Material 3 Expressive FAB menu: the FAB turns into a close button and the
/// ways to start fan out above it as labeled tonal pills. Tapping outside, an
/// item, or the close button folds it away.
class NewNoteFabMenu extends StatefulWidget {
  const NewNoteFabMenu({super.key});

  @override
  State<NewNoteFabMenu> createState() => _NewNoteFabMenuState();
}

class _NewNoteFabMenuState extends State<NewNoteFabMenu> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  bool get _open => _anim.status == AnimationStatus.forward || _anim.status == AnimationStatus.completed;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _toggle() => setState(() => _open ? _anim.reverse() : _anim.forward());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kinds = NewKind.values.toList();
    return TapRegion(
      onTapOutside: (_) {
        if (_open) _toggle();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 8,
        children: [
          for (final (i, kind) in kinds.indexed)
            // each item rises in turn, the nearest to the FAB first
            AnimatedBuilder(
              animation: _anim,
              builder: (context, child) {
                final start = (kinds.length - 1 - i) * 0.12;
                final t = Curves.easeOutBack.transform(((_anim.value - start) / (1 - start)).clamp(0, 1));
                return t == 0
                    ? const SizedBox.shrink()
                    : Opacity(
                        opacity: t.clamp(0, 1),
                        child: Transform.translate(offset: Offset(0, (1 - t) * 16), child: child),
                      );
              },
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 56),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  textStyle: Theme.of(context).textTheme.titleMedium,
                ),
                onPressed: kind.available
                    ? () {
                        _toggle();
                        startNote(context, kind);
                      }
                    : null,
                icon: Icon(kind.icon),
                label: Text(kind.available ? kind.label : '${kind.label} (soon)'),
              ),
            ),
          FloatingActionButton(
            tooltip: _open ? 'Close' : 'New',
            elevation: 0,
            shape: _open ? const CircleBorder() : null,
            backgroundColor: _open ? scheme.primary : null,
            foregroundColor: _open ? scheme.onPrimary : null,
            onPressed: _toggle,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, a) => RotationTransition(turns: a, child: child),
              child: Icon(_open ? Icons.close : Icons.add, key: ValueKey(_open)),
            ),
          ),
        ],
      ),
    );
  }
}
