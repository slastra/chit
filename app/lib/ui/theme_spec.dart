import 'package:material_ui/material_ui.dart';

/// An optional desktop theme from `$XDG_CONFIG_HOME/chit/theme.json`, every
/// field optional. tint renders it from the desktop's scheme; anything else
/// may write it too. The app watches the file and recolors live.
///
///     {"brightness": "dark", "accent": "#bebeda", "background": "#000000",
///      "foreground": "#cdcdcd", "surface": "#080808", "container": "#171717",
///      "outline": "#292929", "error": "#e08398", "font": "Martian Grotesk",
///      "radius": 8}
final class ThemeSpec {
  const ThemeSpec({
    required this.brightness,
    this.accent,
    this.background,
    this.foreground,
    this.surface,
    this.container,
    this.outline,
    this.error,
    this.font,
    this.radius,
  });

  final Brightness brightness;
  final Color? accent, background, foreground, surface, container, outline, error;
  final String? font;
  final double? radius;

  static Color? _color(Object? v) {
    if (v is! String) return null;
    final hex = v.replaceFirst('#', '');
    final n = int.tryParse(hex.length == 6 ? 'ff$hex' : hex, radix: 16);
    return n == null || hex.length != 6 && hex.length != 8 ? null : Color(n);
  }

  static ThemeSpec? fromJson(Object? j) {
    if (j is! Map) return null;
    return ThemeSpec(
      brightness: j['brightness'] == 'light' ? Brightness.light : Brightness.dark,
      accent: _color(j['accent']),
      background: _color(j['background']),
      foreground: _color(j['foreground']),
      surface: _color(j['surface']),
      container: _color(j['container']),
      outline: _color(j['outline']),
      error: _color(j['error']),
      font: (j['font'] as String?)?.trim().isEmpty ?? true ? null : (j['font'] as String).trim(),
      radius: (j['radius'] as num?)?.toDouble(),
    );
  }

  /// Material's tones from the accent, with the exact background, text and
  /// container steps laid over them (stepped from background toward text when
  /// not given, as tint and lastshell derive their neutrals).
  ColorScheme scheme(Color fallbackSeed) {
    final base = ColorScheme.fromSeed(
      seedColor: accent ?? fallbackSeed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    final bg = background ?? base.surface;
    final fg = foreground ?? base.onSurface;
    Color step(double t) => Color.lerp(bg, fg, t)!;
    Color on(Color c) => c.computeLuminance() > 0.4 ? Colors.black : Colors.white;
    return base.copyWith(
      primary: accent,
      onPrimary: accent == null ? null : on(accent!),
      surface: bg,
      onSurface: fg,
      onSurfaceVariant: step(0.66),
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface ?? step(0.04),
      surfaceContainer: step(0.06),
      surfaceContainerHigh: container ?? step(0.09),
      surfaceContainerHighest: step(0.13),
      outline: outline ?? step(0.2),
      outlineVariant: step(0.14),
      error: error,
    );
  }
}
