import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

/// chit's mark, drawn in one color from the scheme. Its face is cut out of
/// the body, so whatever is behind it shows through the eyes and mouth.
/// Three cuts of the same drawing, each for the sizes it survives at: the
/// full face from 64dp, the icon cut (no cheeks, sparkles or tongue) from
/// 32dp, and the tiny cut (eye dots and smile) below that.
class ChitMark extends StatelessWidget {
  const ChitMark({super.key, required this.size, this.color, this.semanticLabel = 'chit'});

  final double size;

  /// Defaults to the scheme's primary, the bare mark on a page.
  final Color? color;
  final String? semanticLabel;

  static String _asset(double size) => switch (size) {
    >= 64 => 'assets/brand/chit-full.svg',
    >= 32 => 'assets/brand/chit-icon.svg',
    _ => 'assets/brand/chit-tiny.svg',
  };

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    _asset(size),
    width: size,
    height: size,
    semanticsLabel: semanticLabel,
    excludeFromSemantics: semanticLabel == null,
    colorFilter: ColorFilter.mode(color ?? Theme.of(context).colorScheme.primary, BlendMode.srcIn),
  );
}

/// The mark on its tonal tile, the app icon's treatment: on-primary-container
/// on primary container, in [shape] (the app icon's rounded square unless
/// given, e.g. an Expressive shape on the sign-in page).
class ChitTile extends StatelessWidget {
  const ChitTile({super.key, required this.size, this.shape});

  final double size;
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: scheme.primaryContainer,
        shape: shape ?? RoundedRectangleBorder(borderRadius: BorderRadius.circular(size * 0.22)),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: ChitMark(size: size * 0.6875, color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}
