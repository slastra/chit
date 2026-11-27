import 'package:material_ui/material_ui.dart';

import 'layout.dart';

/// Note colors by name (the server stores the name). Each hue seeds a tonal
/// scheme, so a colored note reads well in light and dark alike. These use
/// the tonal-spot variant: it keeps the seed's hue (the app's Expressive
/// variant deliberately rotates hues, and turned teal into olive) and puts
/// containers at dark tones in dark mode (fidelity put the bright seed
/// itself there, too light to read on).
const noteHues = <String, Color>{
  'red': Color(0xFFE06C75),
  'orange': Color(0xFFE5965B),
  'yellow': Color(0xFFE5C07B),
  'green': Color(0xFF8FBF6F),
  'teal': Color(0xFF56B6C2),
  'blue': Color(0xFF61AFEF),
  'purple': Color(0xFFA98BE0),
  'pink': Color(0xFFE88FC1),
  'brown': Color(0xFFB08A68),
  'gray': Color(0xFF8A9099),
};

final _cache = <(String, Brightness), ColorScheme>{};

/// The scheme a note of [name] is drawn in, or null for no color.
ColorScheme? noteScheme(String name, Brightness brightness) {
  final hue = noteHues[name];
  if (hue == null) return null;
  return _cache[(name, brightness)] ??= ColorScheme.fromSeed(
    seedColor: hue,
    brightness: brightness,
    // tonal spot lifts chroma, which turns the muted seeds into their hue
    // (gray went blue, brown went orange); those two keep their muted look
    dynamicSchemeVariant: switch (name) {
      'gray' || 'brown' => DynamicSchemeVariant.neutral,
      _ => DynamicSchemeVariant.tonalSpot,
    },
  );
}

/// The color button: on expanded windows a popover beside it (a menu,
/// Material's pattern for a small anchored choice); on compact ones a
/// bottom sheet.
class ColorButton extends StatelessWidget {
  const ColorButton({super.key, required this.current, required this.onPick});
  final String current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (isExpanded(context)) {
      return MenuAnchor(
        builder: (context, ctl, _) => IconButton(
          tooltip: 'Background color',
          icon: const Icon(Icons.palette_outlined),
          onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
        ),
        menuChildren: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: 348, // two rows of six
              // a menu closes once a choice is made
              child: Builder(
                builder: (context) => NoteSwatches(
                  current: current,
                  onPick: (c) {
                    onPick(c);
                    MenuController.maybeOf(context)?.close();
                  },
                ),
              ),
            ),
          ),
        ],
      );
    }
    return IconButton(
      tooltip: 'Background color',
      icon: const Icon(Icons.palette_outlined),
      onPressed: () => showColorSheet(context, current: current, onPick: onPick),
    );
  }
}

/// The colors as a bottom sheet.
Future<void> showColorSheet(BuildContext context, {required String current, required ValueChanged<String> onPick}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ColorSheet(current: current, onPick: onPick),
    );

/// The note colors as a sheet. The chosen one carries a check, so the choice
/// does not rest on color alone.
class _ColorSheet extends StatelessWidget {
  const _ColorSheet({required this.current, required this.onPick});
  final String current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Color', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            NoteSwatches(
              current: current,
              onPick: (c) {
                onPick(c);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The ten note colors and "default", the chosen one checked.
class NoteSwatches extends StatelessWidget {
  const NoteSwatches({super.key, required this.current, required this.onPick});
  final String current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final name in ['', ...noteHues.keys])
        _Swatch(name: name, selected: name == current, onTap: () => onPick(name)),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.selected, required this.onTap});
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = noteScheme(name, theme.brightness);
    // "Default" is no color: an empty ring, whatever color the note has now
    final fill = scheme?.primaryContainer ?? Colors.transparent;
    final ink = scheme?.onPrimaryContainer ?? theme.colorScheme.onSurface;
    final label = name.isEmpty ? 'Default' : '${name[0].toUpperCase()}${name.substring(1)}';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label color',
        child: InkResponse(
          onTap: onTap,
          radius: 28,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: selected
                ? Icon(Icons.check, color: ink)
                : (name.isEmpty
                      ? Icon(Icons.format_color_reset_outlined, color: theme.colorScheme.onSurfaceVariant)
                      : null),
          ),
        ),
      ),
    );
  }
}
