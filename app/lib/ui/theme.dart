import 'package:material_ui/material_ui.dart';

import 'theme_spec.dart';

/// chit's seed when the platform has no wallpaper colors (desktop, web).
const seed = Color(0xFF4F7CAC);

/// Material 3 Expressive wherever material_ui has it: the Expressive color
/// scheme variant, Expressive icon buttons and buttons, and the forward-fade
/// page transition. The rest is standard Material 3.
ThemeData buildTheme(ColorScheme? dynamicScheme, Brightness brightness, [ThemeSpec? spec]) => spec != null
    ? themeFor(spec.scheme(seed), spec)
    : themeFor(
        dynamicScheme?.harmonized(brightness) ??
            ColorScheme.fromSeed(
              seedColor: seed,
              brightness: brightness,
              dynamicSchemeVariant: DynamicSchemeVariant.expressive,
            ),
      );

/// The app's theme around any scheme (a note's page uses its color's). Built
/// whole, not copied: a copied theme keeps its old text colors. [spec] adds
/// the desktop's font and corner radius.
ThemeData themeFor(ColorScheme scheme, [ThemeSpec? spec]) {
  const expressive = StyleVariant.material3Expressive;
  final radius = spec?.radius;
  final corners = radius == null ? null : RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  return ThemeData(
    colorScheme: scheme,
    fontFamily: spec?.font,
    searchBarTheme: corners == null ? null : SearchBarThemeData(shape: WidgetStatePropertyAll(corners)),
    floatingActionButtonTheme: corners == null ? null : FloatingActionButtonThemeData(shape: corners),
    iconButtonTheme: const IconButtonThemeData(variant: expressive),
    elevatedButtonTheme: const ElevatedButtonThemeData(variant: expressive),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final p in TargetPlatform.values) p: const FadeForwardsPageTransitionsBuilder()},
    ),
    inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
    cardTheme: CardThemeData(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias, shape: corners),
    dialogTheme: corners == null ? null : DialogThemeData(shape: corners),
    // sheets and menus a step above the page, so they read on a black one
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: scheme.surfaceContainerHigh),
    menuTheme: MenuThemeData(style: MenuStyle(backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh))),
  );
}

extension on ColorScheme {
  /// A wallpaper scheme rebuilt with the Expressive variant, so Android's
  /// colors keep the same character as the seed scheme.
  ColorScheme harmonized(Brightness b) =>
      ColorScheme.fromSeed(seedColor: primary, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.expressive);
}
