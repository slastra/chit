part of 'home_page.dart';

// The board's furniture: where the FAB slot sits, the empty shelf, a
// dragged card's place, the pin drop zone.

/// How far the selection check hangs off a card's corner, into the grid's
/// gap: room the grid gives each card's box so the check is under the
/// pointer there.
const _checkOverhang = 10.0;

/// The FAB slot's place over the board, which has a rail [start] wide
/// before it and the detail pane's [end] after it: afloat at the foot,
/// [centered] in the board (the selection toolbar) or at its end (the FAB).
class _BoardFloat extends StandardFabLocation with FabFloatOffsetY {
  const _BoardFloat({required this.start, required this.end, required this.centered});
  final double start;
  final double end;
  final bool centered;

  @override
  double getOffsetX(ScaffoldPrelayoutGeometry g, double adjustment) {
    final rtl = g.textDirection == TextDirection.rtl;
    final left = rtl ? end : start, right = rtl ? start : end;
    final fab = g.floatingActionButtonSize.width;
    if (centered) return left + (g.scaffoldSize.width - left - right - fab) / 2;
    return rtl
        ? left + kFloatingActionButtonMargin + g.minInsets.left
        : g.scaffoldSize.width - right - kFloatingActionButtonMargin - g.minInsets.right - fab;
  }

  @override
  bool operator ==(Object other) =>
      other is _BoardFloat && other.start == start && other.end == end && other.centered == centered;

  @override
  int get hashCode => Object.hash(start, end, centered);
}

/// An empty shelf: an Expressive shape with the shelf's glyph in it.
class _Empty extends StatelessWidget {
  const _Empty({required this.shelf, required this.searching});
  final Shelf shelf;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = searching
        ? 'No notes match'
        : switch (shelf) {
            Shelf.notes => 'Notes you add appear here',
            Shelf.archive => 'Archived notes appear here',
            Shelf.trash => 'No notes in the trash',
            Shelf.reminders => 'Notes with reminders appear here',
            Shelf.labeled => 'No notes with this label yet',
          };
    return Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Column(
        children: [
          // an empty board is where the mark lives, bare, in primary: chit,
          // waiting for its first note; other shelves and searches keep their
          // glyph on the Expressive cookie
          if (shelf == Shelf.notes && !searching)
            const ChitMark(size: 120, semanticLabel: null)
          else
            DecoratedBox(
              decoration: ShapeDecoration(
                color: scheme.primaryContainer,
                shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
              ),
              child: SizedBox.square(
                dimension: 96,
                child: Icon(searching ? Icons.search_off : shelf.icon, size: 40, color: scheme.onPrimaryContainer),
              ),
            ),
          const SizedBox(height: 24),
          Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A card that may be out on a drag: kept in the tree (its state, its
/// pending checks) but unseen, with its slot drawn in its place.
class _Placeable extends StatelessWidget {
  const _Placeable({required this.hidden, required this.overhang, required this.child});
  final bool hidden;

  /// The child's box starts this far up and left of its card.
  final double overhang;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = cardRadius(context);
    return Stack(
      children: [
        Positioned.fill(
          top: overhang,
          left: overhang,
          child: AnimatedOpacity(
            opacity: hidden ? 1 : 0,
            duration: Durations.short2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: radius,
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
          ),
        ),
        Visibility(visible: !hidden, maintainState: true, maintainAnimation: true, maintainSize: true, child: child),
      ],
    );
  }
}

/// Somewhere to drop a note to pin it, while dragging and nothing is
/// pinned: a dashed outline (the drop-here sign) in the card shape, a pin in
/// a tonal circle, and what it does.
class PinDropZone extends StatelessWidget {
  const PinDropZone({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = cardRadius(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CustomPaint(
        foregroundPainter: _DashedOutline(color: scheme.outline, radius: radius),
        child: Container(
          height: 88,
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: radius),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 16,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: scheme.secondaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.push_pin_outlined, size: 20, color: scheme.onSecondaryContainer),
              ),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text('Drop here to pin', style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface)),
                    Text(
                      'Pinned notes stay on top',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dashed rounded-rectangle outline.
class _DashedOutline extends CustomPainter {
  const _DashedOutline({required this.color, required this.radius});
  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(radius.toRRect(Offset.zero & size).deflate(0.75));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline old) => old.color != color || old.radius != radius;
}
