import 'package:material_ui/material_ui.dart';

import 'theme_spec.dart';

/// chit's seed when the platform has no wallpaper colors (desktop, web).
const seed = Color(0xFF4F7CAC);

/// Material 3 Expressive wherever material_ui has it: Expressive icon
/// buttons and buttons, and the forward-fade page transition. Colors come
/// from the desktop's theme file, Android's own scheme, or chit's seed as a
/// tonal-spot scheme. The rest is standard Material 3.
ThemeData buildTheme(ColorScheme? dynamicScheme, Brightness brightness, [ThemeSpec? spec]) => spec != null
    ? themeFor(spec.scheme(seed), spec)
    : themeFor(
        dynamicScheme?.harmonized(brightness) ??
            // nothing to follow (the web, a desktop with no theme file):
            // chit's blue as Android builds a scheme from a wallpaper. The
            // Expressive variant rotates hues on purpose, which from one
            // seed came out green and pink
            ColorScheme.fromSeed(
              seedColor: seed,
              brightness: brightness,
              dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
            ),
      );

/// Material's shape scale (extra small 4, small 8, medium 12, large 16,
/// extra large 28, full), scaled as a whole so its medium step is the
/// desktop's corner radius. Each component keeps its own step, so dialogs
/// stay rounder than cards and cards rounder than menus, as the spec ranks
/// them; full (search bar, buttons, chips' pills) stays full.
final class ShapeScale {
  const ShapeScale([this.factor = 1]);
  factory ShapeScale.of(ThemeSpec? spec) => ShapeScale(spec?.radius == null ? 1 : spec!.radius! / 12);
  final double factor;
  double get extraSmall => 4 * factor;
  double get small => 8 * factor;
  double get medium => 12 * factor;
  double get large => 16 * factor;
  double get extraLarge => 28 * factor;
  RoundedRectangleBorder rounded(double r) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
}

/// The app's theme around any scheme (a note's page uses its color's). Built
/// whole, not copied: a copied theme keeps its old text colors. [spec] adds
/// the desktop's font and scales the shape scale to its corner radius.
/// Component colors are left to Material's roles; the tint scheme's surface
/// ladder is what keeps containers apart on a black background.
ThemeData themeFor(ColorScheme scheme, [ThemeSpec? spec]) {
  const expressive = StyleVariant.material3Expressive;
  final shapes = ShapeScale.of(spec);
  return ThemeData(
    colorScheme: scheme,
    fontFamily: spec?.font,
    floatingActionButtonTheme: FloatingActionButtonThemeData(shape: shapes.rounded(shapes.large)),
    iconButtonTheme: const IconButtonThemeData(variant: expressive),
    elevatedButtonTheme: const ElevatedButtonThemeData(variant: expressive),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final p in TargetPlatform.values) p: const FadeForwardsPageTransitionsBuilder()},
    ),
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: shapes.rounded(shapes.medium),
    ),
    dialogTheme: DialogThemeData(shape: shapes.rounded(shapes.extraLarge)),
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(shapes.extraLarge))),
    ),
    snackBarTheme: SnackBarThemeData(shape: shapes.rounded(shapes.extraSmall)),
    // Material 3 Expressive's vertical menu (SegmentedMenuTokens): a large
    // (16dp) container at level 2, 4dp inside it (on surface container, the
    // baseline menu's tone: the Expressive surface container low all but
    // vanishes on a black background, where shadows do not show);
    // items 44dp tall with their own medium shape, 16dp from the menu's
    // edge to their content, 20dp icons, body-large labels
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(shapes.rounded(shapes.large)),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(3),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shapes.rounded(shapes.medium)),
        minimumSize: const WidgetStatePropertyAll(Size(112, 44)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        iconSize: const WidgetStatePropertyAll(20),
        // body large (16/24, +0.5), in the theme's own font
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontFamily: spec?.font, fontSize: 16, height: 1.5, letterSpacing: 0.5, fontWeight: FontWeight.w400),
        ),
      ),
    ),
    // top app bars: surface, and surface container once content scrolls
    // under them (the spec's on-scroll color, rather than a tint)
    appBarTheme: AppBarThemeData(
      backgroundColor: WidgetStateColor.resolveWith(
        (s) => s.contains(WidgetState.scrolledUnder) ? scheme.surfaceContainer : scheme.surface,
      ),
      scrolledUnderElevation: 0,
    ),
    chipTheme: ChipThemeData(shape: shapes.rounded(shapes.small)),
    // the 2024 progress indicators: a gap between track and indicator, and
    // the stop dot
    // (the flag is deprecated only because false becomes the default)
    // ignore: deprecated_member_use
    progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
    // the 2024 slider too: a thick track with a gap and a bar handle
    // ignore: deprecated_member_use
    sliderTheme: const SliderThemeData(year2023: false),
  );
}

extension on ColorScheme {
  /// A wallpaper scheme on Android 12 and 13, which publish only tonal
  /// palettes: rebuilt the way Android builds its own (tonal spot), so it
  /// comes close to the system's. Android 14+ hands over the scheme itself
  /// (system_colors.dart).
  ColorScheme harmonized(Brightness b) =>
      ColorScheme.fromSeed(seedColor: primary, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot);
}
