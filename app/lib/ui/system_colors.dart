import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

const _channel = MethodChannel('chit/system_colors');

/// Android's own color scheme, light and dark, every role exactly as the
/// system publishes it (Android 14+; MainActivity.kt reads the resources).
/// Null elsewhere, and on older Android, where the wallpaper palette from
/// dynamic_color stands in.
Future<({ColorScheme light, ColorScheme dark})?> systemSchemes() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final m = await _channel.invokeMapMethod<String, Object?>('scheme');
    if (m == null) return null;
    final light = (m['light']! as Map).cast<String, int>();
    final dark = (m['dark']! as Map).cast<String, int>();
    return (light: _scheme(light, dark, Brightness.light), dark: _scheme(dark, light, Brightness.dark));
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// A scheme from the system's roles. Android publishes no inverse roles;
/// those are the other mode's surface, text and primary by definition.
ColorScheme _scheme(Map<String, int> r, Map<String, int> other, Brightness b) {
  Color c(String role) => Color(r[role]!);
  Color o(String role) => Color(other[role]!);
  return ColorScheme(
    brightness: b,
    primary: c('primary'),
    onPrimary: c('on_primary'),
    primaryContainer: c('primary_container'),
    onPrimaryContainer: c('on_primary_container'),
    primaryFixed: c('primary_fixed'),
    primaryFixedDim: c('primary_fixed_dim'),
    onPrimaryFixed: c('on_primary_fixed'),
    onPrimaryFixedVariant: c('on_primary_fixed_variant'),
    secondary: c('secondary'),
    onSecondary: c('on_secondary'),
    secondaryContainer: c('secondary_container'),
    onSecondaryContainer: c('on_secondary_container'),
    secondaryFixed: c('secondary_fixed'),
    secondaryFixedDim: c('secondary_fixed_dim'),
    onSecondaryFixed: c('on_secondary_fixed'),
    onSecondaryFixedVariant: c('on_secondary_fixed_variant'),
    tertiary: c('tertiary'),
    onTertiary: c('on_tertiary'),
    tertiaryContainer: c('tertiary_container'),
    onTertiaryContainer: c('on_tertiary_container'),
    tertiaryFixed: c('tertiary_fixed'),
    tertiaryFixedDim: c('tertiary_fixed_dim'),
    onTertiaryFixed: c('on_tertiary_fixed'),
    onTertiaryFixedVariant: c('on_tertiary_fixed_variant'),
    error: c('error'),
    onError: c('on_error'),
    errorContainer: c('error_container'),
    onErrorContainer: c('on_error_container'),
    surface: c('surface'),
    onSurface: c('on_surface'),
    onSurfaceVariant: c('on_surface_variant'),
    surfaceDim: c('surface_dim'),
    surfaceBright: c('surface_bright'),
    surfaceContainerLowest: c('surface_container_lowest'),
    surfaceContainerLow: c('surface_container_low'),
    surfaceContainer: c('surface_container'),
    surfaceContainerHigh: c('surface_container_high'),
    surfaceContainerHighest: c('surface_container_highest'),
    outline: c('outline'),
    outlineVariant: c('outline_variant'),
    inverseSurface: o('surface'),
    onInverseSurface: o('on_surface'),
    inversePrimary: o('primary'),
    surfaceTint: c('primary'),
    shadow: Colors.black,
    scrim: Colors.black,
  );
}
