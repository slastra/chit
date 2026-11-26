import 'package:material_ui/material_ui.dart';

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
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
}
