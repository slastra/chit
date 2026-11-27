/// Material 3 Expressive components material_ui (1.11) does not ship yet,
/// built to Compose's tokens (androidx material3/tokens): the loading
/// indicator, the wavy linear progress indicator, the connected button
/// group (which replaces the segmented button), and the docked and floating
/// toolbars (which replace the bottom app bar).
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

/// Sideways scrolling a mouse can drag, without a scrollbar: for rows and
/// carousels, which a wheel alone cannot reach along.
ScrollBehavior anyPointerScroll(BuildContext context) =>
    ScrollConfiguration.of(context).copyWith(dragDevices: {...PointerDeviceKind.values}, scrollbars: false);

// ---- loading indicator -------------------------------------------------------

/// Material's loading indicator, for waits of a few seconds (it replaces
/// most indeterminate circular indicators): a shape that turns as it morphs
/// through a set of Material shapes. LoadingIndicatorTokens: a 38dp shape
/// in a 48dp box, in primary; [contained] sets it on a primary container
/// circle in on primary container. [size] scales the whole thing.
class LoadingIndicator extends StatefulWidget {
  const LoadingIndicator({super.key, this.size = 48, this.color, this.contained = false});
  final double size;
  final Color? color;
  final bool contained;

  @override
  State<LoadingIndicator> createState() => _LoadingIndicatorState();
}

class _LoadingIndicatorState extends State<LoadingIndicator> with SingleTickerProviderStateMixin {
  // Compose's sequence
  static final _shapes = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ].map((s) => MaterialShapeBorder(shape: s)).toList();

  static const _perShape = Duration(milliseconds: 650);

  late final _ctl = AnimationController(vsync: this, duration: _perShape * _shapes.length)..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? (widget.contained ? scheme.onPrimaryContainer : scheme.primary);
    final shape = AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        final at = _ctl.value * _shapes.length;
        final i = at.floor() % _shapes.length;
        // each morph eases in and out; the turn carries on through it
        final f = Curves.easeInOutCubicEmphasized.transform(at - at.floor());
        return Transform.rotate(
          angle: (i + f) * math.pi / 2,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: color,
              shape: ShapeBorder.lerp(_shapes[i], _shapes[(i + 1) % _shapes.length], f)!,
            ),
          ),
        );
      },
    );
    return Semantics(
      label: 'Loading',
      child: SizedBox.square(
        dimension: widget.size,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: widget.contained ? scheme.primaryContainer : null),
          child: Center(
            child: SizedBox.square(dimension: widget.size * 38 / 48, child: shape),
          ),
        ),
      ),
    );
  }
}

// ---- wavy progress -----------------------------------------------------------

/// Material's wavy linear progress indicator: the done part a wave (3dp
/// amplitude, 40dp wavelength, 4dp thick), a 4dp gap, then the flat track,
/// with the stop dot at its end. The wave travels while [moving] (something
/// is playing, working) and flattens near the ends, where there is no room
/// for it. With no [value] it is indeterminate: a length of wave crossing
/// the track, over and over.
class WavyProgress extends StatefulWidget {
  const WavyProgress({super.key, required this.value, this.moving = true, this.color, this.trackColor});
  final double? value;
  final bool moving;
  final Color? color;
  final Color? trackColor;

  @override
  State<WavyProgress> createState() => _WavyProgressState();
}

class _WavyProgressState extends State<WavyProgress> with SingleTickerProviderStateMixin {
  // two wavelengths in a turn; the indeterminate length crosses once
  late final _ctl = AnimationController(vsync: this, duration: const Duration(seconds: 2));

  bool get _moving => widget.moving || widget.value == null;

  @override
  void initState() {
    super.initState();
    if (_moving) _ctl.repeat();
  }

  @override
  void didUpdateWidget(WavyProgress old) {
    super.didUpdateWidget(old);
    if (_moving && !_ctl.isAnimating) {
      _ctl.repeat();
    } else if (!_moving && _ctl.isAnimating) {
      _ctl.stop();
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = widget.value;
    return Semantics(
      label: value == null ? 'Loading' : null,
      value: value == null ? null : '${(value * 100).round()}%',
      child: SizedBox(
        height: 10, // the track's 4dp and the wave's 3dp either side
        // the controller repaints the painter alone, no rebuild a frame
        child: CustomPaint(
          painter: _WavePainter(
            value: value?.clamp(0.0, 1.0),
            turn: _ctl,
            color: widget.color ?? scheme.primary,
            track: widget.trackColor ?? scheme.secondaryContainer,
            rtl: Directionality.of(context) == TextDirection.rtl,
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.value, required this.turn, required this.color, required this.track, required this.rtl})
    : super(repaint: turn);
  final double? value;
  final Animation<double> turn;
  final Color color;
  final Color track;
  final bool rtl;

  static const _thickness = 4.0;
  static const _amplitude = 3.0;
  static const _wavelength = 40.0;
  static const _gap = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final mid = size.height / 2;
    const r = _thickness / 2;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _thickness
      ..strokeCap = StrokeCap.round;
    final at = turn.value;
    final phase = at * 2;

    void line(double from, double to) {
      if (to > from) canvas.drawLine(Offset(from, mid), Offset(to, mid), stroke..color = track);
    }

    // a wave from [from] to [to], easing to the center line at its ends
    void wave(double from, double to, double amp) {
      if (to <= from) return;
      double y(double x) {
        final ends = math.min(1.0, math.min(x - from, to - x) / 12);
        return mid + amp * ends * math.sin((x / _wavelength - phase) * 2 * math.pi);
      }

      final path = Path()..moveTo(from, y(from));
      for (var x = from + 1; x < to; x += 1) {
        path.lineTo(x, y(x));
      }
      canvas.drawPath(path..lineTo(to, y(to)), stroke..color = color);
    }

    final value = this.value;
    if (value == null) {
      // a third of the track's length, in from the start and out the end
      final length = size.width / 3;
      final head = (size.width + length) * Curves.easeInOut.transform(at);
      final from = math.max(r, head - length), to = math.min(size.width - r, head);
      line(r, from - _gap - r);
      wave(from, to, _amplitude);
      line(to + _gap + r, size.width - r);
      return;
    }
    final end = size.width * value;
    // the track, after the gap, with its stop dot
    line(end + (value > 0 ? _gap + r : r), size.width - r);
    canvas.drawCircle(Offset(size.width - r, mid), r, Paint()..color = color);
    // the wave: full between 10% and 95%, flat towards either end
    final amp = _amplitude * (value < 0.1 ? value / 0.1 : (value > 0.95 ? (1 - value) / 0.05 : 1.0));
    wave(r, end - r, amp);
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.value != value || old.turn != turn || old.color != color || old.track != track || old.rtl != rtl;
}

// ---- connected button group --------------------------------------------------

/// Material's connected button group, one choice of several (it replaces
/// the segmented button). ConnectedButtonGroupSmallTokens: 40dp tall, 2dp
/// apart, fully round at the group's ends and 8dp at the inner corners; the
/// selected one goes fully round, in primary.
class ConnectedButtonGroup<T> extends StatelessWidget {
  const ConnectedButtonGroup({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.tooltip,
  });
  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;
  final String Function(T value)? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const outer = Radius.circular(20), inner = Radius.circular(8);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (final (i, v) in values.indexed)
          Builder(
            builder: (context) {
              final on = v == selected;
              final shape = RoundedRectangleBorder(
                borderRadius: on
                    ? const BorderRadius.all(outer)
                    : BorderRadiusDirectional.horizontal(
                        start: i == 0 ? outer : inner,
                        end: i == values.length - 1 ? outer : inner,
                      ).resolve(Directionality.of(context)),
              );
              final button = Semantics(
                button: true,
                selected: on,
                inMutuallyExclusiveGroup: true,
                child: AnimatedContainer(
                  duration: Durations.short4,
                  curve: Easing.standard,
                  height: 40,
                  constraints: const BoxConstraints(minWidth: 48),
                  decoration: ShapeDecoration(color: on ? scheme.primary : scheme.surfaceContainer, shape: shape),
                  clipBehavior: Clip.antiAlias,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: on ? null : () => onSelected(v),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            label(v),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              return tooltip == null ? button : Tooltip(message: tooltip!(v), child: button);
            },
          ),
      ],
    );
  }
}

// ---- docked toolbar ----------------------------------------------------------

/// Material's docked toolbar, along the foot of a page (it replaces the
/// bottom app bar). DockedToolbarTokens: 64dp tall, 16dp at either end, on
/// surface container, square, no elevation. [color] overrides the
/// container (a toolbar inside a dialog sits on the dialog's own).
class DockedToolbar extends StatelessWidget {
  const DockedToolbar({super.key, required this.children, this.color});
  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color ?? scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: IconTheme.merge(
          data: IconThemeData(color: scheme.onSurfaceVariant),
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: children),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- floating toolbar ----------------------------------------------------------

/// Material's floating toolbar: actions for what is on the page, afloat
/// over its foot. FloatingToolbarTokens: 64dp tall and fully round, 8dp
/// inside its ends, 4dp between items, 16dp clear of the window's edges
/// (the caller's to keep), at elevation level 3. Standard is on surface
/// container; [vibrant], for a mode that wants notice (a selection), is on
/// primary container.
class FloatingToolbar extends StatelessWidget {
  const FloatingToolbar({super.key, required this.children, this.vibrant = false});
  final List<Widget> children;
  final bool vibrant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = vibrant ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: vibrant ? scheme.primaryContainer : scheme.surfaceContainer,
      elevation: 3,
      shadowColor: scheme.shadow,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButtonTheme(
        data: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: ink)),
        child: DefaultTextStyle.merge(
          style: theme.textTheme.titleMedium?.copyWith(color: vibrant ? scheme.onPrimaryContainer : scheme.onSurface),
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: children),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- wavy seek track -----------------------------------------------------------

/// A slider track for playback: what has played is the wavy line of
/// Material's wavy progress indicator (3dp amplitude, 40dp wavelength, 4dp
/// thick), what is left a flat one with the stop dot at its end, a gap
/// either side of the handle. [phase] (0 to 1) moves the wave along;
/// [swell] (0 to 1) is how much of its amplitude it has, so it can settle
/// flat when playback pauses or the handle is dragged.
class WavyTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const WavyTrackShape({required this.phase, required this.swell});
  final double phase;
  final double swell;

  static const _amplitude = 3.0;
  static const _wavelength = 40.0;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.height <= 0) return;
    final active = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    ).evaluate(enableAnimation)!;
    final inactive = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    ).evaluate(enableAnimation)!;
    final canvas = context.canvas;
    final r = rect.height / 2;
    final mid = rect.center.dy;
    final gap = sliderTheme.trackGap ?? 6;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = rect.height
      ..strokeCap = StrokeCap.round;
    canvas.save();
    if (textDirection == TextDirection.rtl) {
      // drawn left to right, mirrored about the track
      canvas
        ..translate(rect.left + rect.right, 0)
        ..scale(-1, 1);
    }
    final thumb = textDirection == TextDirection.rtl ? rect.left + rect.right - thumbCenter.dx : thumbCenter.dx;
    // played: the wave, easing to the center line at either end
    final from = rect.left + r, to = thumb - gap - r;
    if (to > from) {
      final amp = _amplitude * swell;
      double y(double x) {
        final ends = math.min(1.0, math.min(x - from, to - x) / 12);
        return mid + amp * ends * math.sin((x / _wavelength - phase) * 2 * math.pi);
      }

      final path = Path()..moveTo(from, y(from));
      for (var x = from + 1; x < to; x += 1) {
        path.lineTo(x, y(x));
      }
      path.lineTo(to, y(to));
      canvas.drawPath(path, stroke..color = active);
    }
    // to come: the flat line, and the stop dot at its end
    final rest = thumb + gap + r, end = rect.right - r;
    if (end > rest) canvas.drawLine(Offset(rest, mid), Offset(end, mid), stroke..color = inactive);
    canvas
      ..drawCircle(Offset(end, mid), r, Paint()..color = active)
      ..restore();
  }
}

// ---- pull to refresh -----------------------------------------------------------

/// Pull to refresh, Expressive's way: the contained loading indicator comes
/// down from the top as the list is pulled, and turns while [onRefresh]
/// runs (it replaces the circular spinner).
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({super.key, required this.onRefresh, required this.child});
  final RefreshCallback onRefresh;
  final Widget child;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

class _PullToRefreshState extends State<PullToRefresh> {
  RefreshIndicatorStatus? _status;

  @override
  Widget build(BuildContext context) {
    // pulled: on its way; far enough, or refreshing: all the way out
    final out = switch (_status) {
      RefreshIndicatorStatus.drag => 0.6,
      RefreshIndicatorStatus.armed || RefreshIndicatorStatus.snap || RefreshIndicatorStatus.refresh => 1.0,
      _ => 0.0,
    };
    return Stack(
      children: [
        RefreshIndicator.noSpinner(
          onRefresh: widget.onRefresh,
          onStatusChange: (s) {
            // far enough to let go: felt
            if (s == RefreshIndicatorStatus.armed) unawaited(HapticFeedback.selectionClick());
            setState(() => _status = s);
          },
          child: widget.child,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SafeArea(
              child: Center(
                child: AnimatedSlide(
                  offset: Offset(0, out == 0 ? -1.2 : (out < 1 ? 0.1 : 0.6)),
                  duration: Durations.medium2,
                  curve: Easing.emphasizedDecelerate,
                  child: AnimatedOpacity(
                    opacity: out == 0 ? 0 : (out < 1 ? 0.7 : 1),
                    duration: Durations.short4,
                    child: AnimatedScale(
                      scale: out == 0 ? 0.4 : (out < 1 ? 0.8 : 1),
                      duration: Durations.medium2,
                      curve: Easing.emphasizedDecelerate,
                      child: out == 0
                          ? const SizedBox.square(dimension: 48)
                          : const Material(
                              type: MaterialType.circle,
                              color: Colors.transparent,
                              elevation: 3,
                              child: LoadingIndicator(contained: true),
                            ),
                    ),
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

// ---- segmented list ------------------------------------------------------------

/// Expressive's segmented list: the rows of a group as separate containers
/// 2dp apart, the group's outer corners large (16dp) and the corners
/// between rows extra small (4dp), on a brighter surface than what they
/// sit on. Each child is a row (a ListTile and its kin).
class SegmentedList extends StatelessWidget {
  const SegmentedList({super.key, required this.children, this.padding = const EdgeInsets.symmetric(horizontal: 16)});
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const outer = Radius.circular(16), inner = Radius.circular(4);
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 2,
        children: [
          for (final (i, child) in children.indexed)
            Material(
              color: scheme.surfaceBright,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: i == 0 ? outer : inner,
                  bottom: i == children.length - 1 ? outer : inner,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
        ],
      ),
    );
  }
}

// ---- segmented menu ------------------------------------------------------------

/// The popup of a segmented menu: nothing of its own, since its groups are
/// the containers (SegmentedMenuTokens).
final segmentedMenuStyle = MenuStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: const WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  elevation: const WidgetStatePropertyAll(0),
  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
);

/// Expressive's segmented menu: its [groups] as separate containers 2dp
/// apart, the menu's outer corners large (16dp) and the corners between
/// groups small (8dp), each group padded 4dp around its items. An item's
/// corners are extra small (4dp), but medium (12dp) where they meet their
/// group's rounder end.
class SegmentedMenu extends StatelessWidget {
  const SegmentedMenu({super.key, required this.groups});
  final List<List<Widget>> groups;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const outer = Radius.circular(16), inner = Radius.circular(8);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: [
        for (final (g, items) in groups.indexed)
          Material(
            color: scheme.surfaceContainer,
            elevation: 3,
            shadowColor: scheme.shadow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: g == 0 ? outer : inner,
                bottom: g == groups.length - 1 ? outer : inner,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 2,
                children: [
                  for (final (i, item) in items.indexed)
                    _SegmentedMenuPlace(first: i == 0, last: i == items.length - 1, child: item),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Tells a [SegmentedMenuItem] where in its group it is.
class _SegmentedMenuPlace extends InheritedWidget {
  const _SegmentedMenuPlace({required this.first, required this.last, required super.child});
  final bool first;
  final bool last;

  @override
  bool updateShouldNotify(_SegmentedMenuPlace old) => old.first != first || old.last != last;
}

/// An item of a [SegmentedMenu]: 44dp tall, a 20dp icon 12dp from its
/// body-large label. [selected] (where it is the current place or choice)
/// puts it on tertiary container, its corners medium all round.
class SegmentedMenuItem extends StatelessWidget {
  const SegmentedMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final place = context.dependOnInheritedWidgetOfExactType<_SegmentedMenuPlace>();
    const snug = Radius.circular(4), round = Radius.circular(12);
    final ink = selected ? scheme.onTertiaryContainer : null;
    return MenuItemButton(
      style: MenuItemButton.styleFrom(
        backgroundColor: selected ? scheme.tertiaryContainer : null,
        foregroundColor: ink,
        iconColor: ink,
        shape: RoundedRectangleBorder(
          borderRadius: selected
              ? const BorderRadius.all(round)
              : BorderRadius.vertical(
                  top: (place?.first ?? true) ? round : snug,
                  bottom: (place?.last ?? true) ? round : snug,
                ),
        ),
      ),
      leadingIcon: Icon(icon),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
