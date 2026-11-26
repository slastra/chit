/// Material 3 Expressive components material_ui (1.11) does not ship yet,
/// built to Compose's tokens (androidx material3/tokens): the loading
/// indicator, the wavy linear progress indicator, the connected button
/// group (which replaces the segmented button) and the docked toolbar
/// (which replaces the bottom app bar).
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

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

/// Material's wavy linear progress indicator, determinate: the done part a
/// wave (3dp amplitude, 40dp wavelength, 4dp thick), a 4dp gap, then the
/// flat track, with the stop dot at its end. The wave travels while
/// [moving] (something is playing, working) and flattens near the ends,
/// where there is no room for it.
class WavyProgress extends StatefulWidget {
  const WavyProgress({super.key, required this.value, this.moving = true, this.color, this.trackColor});
  final double value;
  final bool moving;
  final Color? color;
  final Color? trackColor;

  @override
  State<WavyProgress> createState() => _WavyProgressState();
}

class _WavyProgressState extends State<WavyProgress> with SingleTickerProviderStateMixin {
  // one wavelength a second
  late final _ctl = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void initState() {
    super.initState();
    if (widget.moving) _ctl.repeat();
  }

  @override
  void didUpdateWidget(WavyProgress old) {
    super.didUpdateWidget(old);
    if (widget.moving && !_ctl.isAnimating) {
      _ctl.repeat();
    } else if (!widget.moving && _ctl.isAnimating) {
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
    return Semantics(
      value: '${(widget.value * 100).round()}%',
      child: SizedBox(
        height: 10, // the track's 4dp and the wave's 3dp either side
        child: AnimatedBuilder(
          animation: _ctl,
          builder: (context, _) => CustomPaint(
            painter: _WavePainter(
              value: widget.value.clamp(0.0, 1.0),
              phase: _ctl.value,
              color: widget.color ?? scheme.primary,
              track: widget.trackColor ?? scheme.secondaryContainer,
              rtl: Directionality.of(context) == TextDirection.rtl,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.value, required this.phase, required this.color, required this.track, required this.rtl});
  final double value;
  final double phase;
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
    final end = size.width * value;
    // the track, after the gap, with its stop dot
    final from = end + (value > 0 ? _gap + r : r);
    if (from < size.width - r) {
      canvas.drawLine(Offset(from, mid), Offset(size.width - r, mid), stroke..color = track);
    }
    canvas.drawCircle(Offset(size.width - r, mid), r, Paint()..color = color);
    if (end <= r) return;
    // the wave: full between 10% and 95%, flat towards either end
    final amp = _amplitude * (value < 0.1 ? value / 0.1 : (value > 0.95 ? (1 - value) / 0.05 : 1.0));
    final path = Path()..moveTo(r, mid + _y(r, amp));
    for (var x = r + 1; x < end - r; x += 1) {
      path.lineTo(x, mid + _y(x, amp));
    }
    canvas.drawPath(path, stroke..color = color);
  }

  double _y(double x, double amp) => amp * math.sin((x / _wavelength - phase) * 2 * math.pi);

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.value != value || old.phase != phase || old.color != color || old.track != track;
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
