import 'package:flutter/physics.dart';
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

/// Animates a value toward [target] on a Material motion spring, and builds
/// with the current value (which overshoots, for the Expressive springs).
/// With reduced motion it jumps.
class SpringValue extends StatefulWidget {
  const SpringValue({super.key, required this.target, required this.spring, required this.builder});
  final double target;
  final SpringDescription spring;
  final Widget Function(BuildContext context, double value) builder;

  @override
  State<SpringValue> createState() => _SpringValueState();
}

class _SpringValueState extends State<SpringValue> with SingleTickerProviderStateMixin {
  late final _c = AnimationController.unbounded(vsync: this, value: widget.target)..addListener(() => setState(() {}));

  @override
  void didUpdateWidget(SpringValue old) {
    super.didUpdateWidget(old);
    if (old.target == widget.target) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = widget.target;
    } else {
      _c.animateWith(SpringSimulation(widget.spring, _c.value, widget.target, _c.velocity));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _c.value);
}

/// Hover, focus and press, for shapes that answer to them.
bool _active(Set<WidgetState> s) =>
    s.contains(WidgetState.pressed) || s.contains(WidgetState.hovered) || s.contains(WidgetState.focused);

/// Material 3 Expressive split button, medium size, filled style (the specs
/// in Compose's SplitButtonMediumTokens): 56dp tall, two halves 2dp apart
/// with fully round outer corners and 4dp inner ones. An inner corner
/// widens to 12dp while its half is hovered, focused or pressed; the menu
/// half is a 56dp square that turns into a circle while its menu is open,
/// with the chevron turned over. The shapes move on the fast spatial spring.
class NewNoteSplitButton extends StatefulWidget {
  const NewNoteSplitButton({super.key});

  @override
  State<NewNoteSplitButton> createState() => _NewNoteSplitButtonState();
}

class _NewNoteSplitButtonState extends State<NewNoteSplitButton> {
  final _leading = WidgetStatesController();
  final _trailing = WidgetStatesController();
  bool _open = false;

  static const _height = 56.0;
  static const _outer = 28.0;
  static const _inner = 4.0;
  static const _innerActive = 12.0;

  @override
  void initState() {
    super.initState();
    for (final c in [_leading, _trailing]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _leading.dispose();
    _trailing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.titleMedium;
    ButtonStyle style(BorderRadius r, {EdgeInsets? padding, Color? background}) => FilledButton.styleFrom(
      minimumSize: const Size(_height, _height),
      fixedSize: const Size.fromHeight(_height),
      padding: padding,
      backgroundColor: background ?? scheme.primary,
      foregroundColor: scheme.onPrimary,
      textStyle: label,
      iconSize: 24,
      // the spring drives the shape; Material's own shape tween would lag it
      animationDuration: Duration.zero,
      shape: RoundedRectangleBorder(borderRadius: r),
    );

    return Row(
      spacing: 2,
      children: [
        Expanded(
          child: SpringValue(
            target: _active(_leading.value) ? _innerActive : _inner,
            spring: Springs.expressiveFastSpatial,
            builder: (context, inner) => FilledButton.icon(
              statesController: _leading,
              style: style(
                BorderRadius.horizontal(
                  left: const Radius.circular(_outer),
                  right: Radius.circular(inner.clamp(0, _outer)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              onPressed: () => startNote(context, NewKind.note),
              icon: Icon(NewKind.note.icon),
              label: const Text('New note'),
            ),
          ),
        ),
        MenuAnchor(
          onOpen: () => setState(() => _open = true),
          onClose: () => setState(() => _open = false),
          alignmentOffset: const Offset(0, 4),
          menuChildren: [
            for (final kind in NewKind.values.where((k) => k != NewKind.note))
              MenuItemButton(
                leadingIcon: Icon(kind.icon),
                // menus have a disabled state (FAB menus do not): Image shows
                // here, unavailable, until attachments land
                trailingIcon: kind.available ? null : Text('Soon', style: Theme.of(context).textTheme.labelSmall),
                onPressed: kind.available ? () => startNote(context, kind) : null,
                child: Text(kind.label),
              ),
          ],
          builder: (context, menu, _) => SpringValue(
            target: _open ? _outer : (_active(_trailing.value) ? _innerActive : _inner),
            spring: Springs.expressiveFastSpatial,
            builder: (context, inner) => Semantics(
              expanded: _open,
              child: FilledButton(
                statesController: _trailing,
                style: style(
                  BorderRadius.horizontal(
                    left: Radius.circular(inner.clamp(0, _outer)),
                    right: const Radius.circular(_outer),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  // checked: a pressed-strength state layer stays on
                  background: _open ? Color.alphaBlend(scheme.onPrimary.withValues(alpha: 0.1), scheme.primary) : null,
                ),
                onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                child: SpringValue(
                  target: _open ? 0.5 : 0,
                  spring: Springs.expressiveFastSpatial,
                  builder: (context, turns) => Transform.rotate(
                    angle: turns * 2 * 3.141592653589793,
                    child: Icon(Icons.keyboard_arrow_down, size: 26, semanticLabel: 'More ways to start'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Material 3 Expressive FAB menu (Compose's FloatingActionButtonMenu and
/// ToggleFloatingActionButton, FabMenuBaselineTokens). The FAB toggles: on a
/// fast spatial spring it turns from a primary-container square into a 56dp
/// primary circle with a smaller close icon. The items are 56dp pills in
/// primary container, 4dp apart and 8dp above the FAB, revealed one after
/// another from the FAB up, each growing out of the right edge. Tap outside,
/// Escape or Back closes it; Tab or Down from the FAB moves to the items.
class NewNoteFabMenu extends StatefulWidget {
  const NewNoteFabMenu({super.key});

  @override
  State<NewNoteFabMenu> createState() => _NewNoteFabMenuState();
}

class _NewNoteFabMenuState extends State<NewNoteFabMenu> with SingleTickerProviderStateMixin {
  // FAB menu items have no disabled state, so only what works today
  static final _kinds = NewKind.values.where((k) => k.available).toList();

  /// How many items show, counted from the FAB up; springs between 0 and
  /// the item count, which staggers the reveal.
  late final _shown = AnimationController.unbounded(vsync: this)
    ..addListener(() => setState(() {}))
    ..addStatusListener((_) => setState(() {}));
  final _firstItem = FocusNode();
  final _fab = FocusNode(debugLabel: 'fab menu');
  bool _open = false;

  @override
  void dispose() {
    _shown.dispose();
    _firstItem.dispose();
    _fab.dispose();
    super.dispose();
  }

  void _set(bool open) {
    if (open == _open) return;
    setState(() => _open = open);
    // keyboard focus comes into the menu with it, so Escape closes it and
    // Tab or Down steps into the items, however it was opened
    if (open) _fab.requestFocus();
    final target = open ? _kinds.length.toDouble() : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _shown.value = target;
    } else {
      _shown.animateWith(SpringSimulation(Springs.expressiveSlowEffects, _shown.value, target, 0));
    }
  }

  KeyEventResult _fabKey(FocusNode _, KeyEvent e) {
    if (!_open || e is! KeyDownEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if ((e.logicalKey == LogicalKeyboardKey.tab && !shift) || e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _firstItem.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown.value.round();
    final n = _kinds.length;
    // closed and settled, the menu is only its FAB, so the scaffold (and a
    // floating snackbar) sees a 56dp FAB rather than the whole menu's height
    final unfolded = _open || _shown.isAnimating;
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _set(false);
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _set(false)},
        child: TapRegion(
          onTapOutside: (_) => _set(false),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (unfolded)
                for (final (i, kind) in _kinds.indexed) ...[
                  _FabMenuItem(
                    kind: kind,
                    visible: i >= n - shown,
                    focusNode: i == 0 ? _firstItem : null,
                    onPressed: () {
                      _set(false);
                      startNote(context, kind);
                    },
                  ),
                  if (i < n - 1) const SizedBox(height: 4),
                ],
              if (unfolded) const SizedBox(height: 8),
              Focus(
                onKeyEvent: _fabKey,
                skipTraversal: true,
                child: _ToggleFab(open: _open, scheme: scheme, focusNode: _fab, onPressed: () => _set(!_open)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FabMenuItem extends StatelessWidget {
  const _FabMenuItem({required this.kind, required this.visible, required this.onPressed, this.focusNode});
  final NewKind kind;
  final bool visible;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // width on the fast spatial spring (it overshoots a little), alpha on the
    // fast effects one, as Compose's MenuItemAnimationNode does
    return SpringValue(
      target: visible ? 1 : 0,
      spring: Springs.expressiveFastEffects,
      builder: (context, alpha) => SpringValue(
        target: visible ? 1 : 0,
        spring: Springs.expressiveFastSpatial,
        builder: (context, width) {
          final hidden = alpha <= 0.01 && !visible;
          return ExcludeSemantics(
            excluding: !visible,
            child: Opacity(
              opacity: alpha.clamp(0, 1),
              child: IgnorePointer(
                ignoring: !visible,
                child: Material(
                  type: hidden ? MaterialType.transparency : MaterialType.canvas,
                  color: scheme.primaryContainer,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: Align(
                    alignment: Alignment.centerRight,
                    widthFactor: width.clamp(0, 2),
                    child: InkWell(
                      focusNode: focusNode,
                      canRequestFocus: visible,
                      onTap: onPressed,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 8,
                            children: [
                              Icon(kind.icon, size: 24, color: scheme.onPrimaryContainer),
                              Text(
                                kind.label,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(color: scheme.onPrimaryContainer),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The FAB that opens and closes the menu: 56dp, from the theme's FAB corner
/// and primary container to a full circle in primary, its icon from 24dp to
/// the 20dp close icon.
class _ToggleFab extends StatelessWidget {
  const _ToggleFab({required this.open, required this.scheme, required this.focusNode, required this.onPressed});
  final bool open;
  final FocusNode focusNode;
  final ColorScheme scheme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final themed = Theme.of(context).floatingActionButtonTheme.shape;
    final corner = themed is RoundedRectangleBorder ? themed.borderRadius.resolve(TextDirection.ltr).topLeft.x : 16.0;
    return SpringValue(
      target: open ? 1 : 0,
      spring: Springs.expressiveFastSpatial,
      builder: (context, p) {
        final t = p.clamp(0.0, 1.0);
        final fg = Color.lerp(scheme.onPrimaryContainer, scheme.onPrimary, t)!;
        return Semantics(
          button: true,
          expanded: open,
          label: open ? 'Close menu' : 'New',
          excludeSemantics: true,
          child: Tooltip(
            message: open ? 'Close' : 'New',
            child: Material(
              color: Color.lerp(scheme.primaryContainer, scheme.primary, t),
              elevation: 6,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(corner + (28 - corner) * t)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                focusNode: focusNode,
                onTap: onPressed,
                child: SizedBox.square(
                  dimension: 56,
                  child: Center(
                    child: Icon(t > 0.5 ? Icons.close : Icons.add, size: 24 - 4 * t, color: fg),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
