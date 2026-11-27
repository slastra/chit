import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Springs;

/// Cards in columns, each placed in whichever column is shortest so far by
/// its real height (the Keep layout), with full-width section headers
/// ([MasonryChild.span]) that start the columns again below them.
///
/// Every card glides to where a new layout puts it, on Material 3
/// Expressive's spatial spring: a reorder, a note arriving or leaving, a
/// search, a change from another device, a new column count. A card whose
/// neighborhood stays the same (one above it growing, say) follows its place
/// directly instead, so cards never overlap while something changes size.
///
/// [overhang] gives each card's box that much of the gap above it and to
/// its left, for something that hangs off the card's corner (a selection
/// check) and must still be under the pointer there. The card pads itself
/// by as much on those two sides, so it is drawn where it always was. The
/// grid insets its columns by the overhang too, so the first column's
/// stays inside the grid: callers take it off their own left margin.
class Masonry extends StatefulWidget {
  const Masonry({super.key, required this.minColumnWidth, this.spacing = 8, this.overhang = 0, required this.children})
    : assert(overhang <= spacing, 'an overhang past the gap would lie on the next card');

  final double minColumnWidth;
  final double spacing;
  final double overhang;
  final List<Widget> children;

  @override
  State<Masonry> createState() => _MasonryState();
}

class _MasonryState extends State<Masonry> with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => _MasonryLayout(
    minColumnWidth: widget.minColumnWidth,
    spacing: widget.spacing,
    overhang: widget.overhang,
    vsync: this,
    // no motion asked for, or tickers muted (a route on top): snap
    animate: !MediaQuery.disableAnimationsOf(context) && TickerMode.valuesOf(context).enabled,
    children: widget.children,
  );
}

/// Marks a grid child: [tag] names it (a note id) for dragging and
/// finding; [span] makes it a full-width header.
class MasonryChild extends ParentDataWidget<MasonryData> {
  const MasonryChild({super.key, this.tag, this.span = false, required super.child});

  final String? tag;
  final bool span;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as MasonryData;
    if (data.tag != tag || data.span != span) {
      data
        ..tag = tag
        ..span = span;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _MasonryLayout;
}

class _MasonryLayout extends MultiChildRenderObjectWidget {
  const _MasonryLayout({
    required this.minColumnWidth,
    required this.spacing,
    required this.overhang,
    required this.vsync,
    required this.animate,
    super.children,
  });

  final double minColumnWidth;
  final double spacing;
  final double overhang;
  final TickerProvider vsync;
  final bool animate;

  @override
  RenderMasonry createRenderObject(BuildContext context) => RenderMasonry(
    minColumnWidth: minColumnWidth,
    spacing: spacing,
    overhang: overhang,
    vsync: vsync,
    animate: animate,
  );

  @override
  void updateRenderObject(BuildContext context, RenderMasonry renderObject) => renderObject
    ..minColumnWidth = minColumnWidth
    ..spacing = spacing
    ..overhang = overhang
    ..vsync = vsync
    ..animate = animate;
}

/// Where a grid child is drawn ([offset], so paint, hit testing and
/// semantics all follow it) and where its layout puts it ([target]).
class MasonryData extends ContainerBoxParentData<RenderBox> {
  String? tag;
  bool span = false;
  Offset target = Offset.zero;
  bool placed = false;
  int column = -1;
  RenderBox? above;
  SpringSimulation? _x;
  SpringSimulation? _y;
  Duration _start = Duration.zero;

  bool get moving => _x != null;
}

/// One child's place: a full-width header, or a card in a column.
typedef MasonryBox = ({double height, bool span});

/// The layout as a pure function: where each child goes, in order, for
/// [columns] columns of [colWidth]. Shared by the render object and by
/// drag previews (where would the cards go if the order were this?).
List<Rect> placeMasonry(List<MasonryBox> boxes, int columns, double colWidth, double spacing) {
  final width = colWidth * columns + spacing * (columns - 1);
  final tops = List<double>.filled(columns, 0);
  var band = 0.0; // where the current band of columns starts
  var cards = false; // any card in the current band
  final rects = <Rect>[];
  for (final b in boxes) {
    if (b.span) {
      final y = cards ? tops.reduce(math.max) - spacing : band;
      rects.add(Rect.fromLTWH(0, y, width, b.height));
      band = y + b.height;
      tops.fillRange(0, columns, band);
      cards = false;
      continue;
    }
    var col = 0;
    for (var c = 1; c < columns; c++) {
      if (tops[c] < tops[col] - 0.5) col = c;
    }
    rects.add(Rect.fromLTWH(col * (colWidth + spacing), tops[col], colWidth, b.height));
    tops[col] += b.height + spacing;
    cards = true;
  }
  return rects;
}

class RenderMasonry extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, MasonryData>, RenderBoxContainerDefaultsMixin<RenderBox, MasonryData> {
  // private named parameters: callers still write minColumnWidth: and so on
  RenderMasonry({
    required this._minColumnWidth,
    required this._spacing,
    this._overhang = 0,
    required this._vsync,
    required this._animate,
  });

  double _minColumnWidth;
  set minColumnWidth(double v) {
    if (v == _minColumnWidth) return;
    _minColumnWidth = v;
    markNeedsLayout();
  }

  double _spacing;
  double get spacing => _spacing;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  /// How far a card's box reaches into the gap above and left of the card.
  double _overhang;
  set overhang(double v) {
    if (v == _overhang) return;
    _overhang = v;
    markNeedsLayout();
  }

  TickerProvider _vsync;
  set vsync(TickerProvider v) {
    if (v == _vsync) return;
    _vsync = v;
    _ticker?.dispose();
    _ticker = null;
    if (_anyMoving) _ensureTicking();
  }

  bool _animate;
  set animate(bool v) {
    if (v == _animate) return;
    _animate = v;
    if (!v) _settleAll();
  }

  Ticker? _ticker;
  Duration _now = Duration.zero;
  int _columns = 0;
  double _width = -1;

  /// How many columns fit [width].
  int columnsFor(double width) => math.max(1, ((width - _overhang + _spacing) / (_minColumnWidth + _spacing)).floor());

  int get columns => _columns;
  double get columnWidth => (_width - _overhang - _spacing * (_columns - 1)) / _columns;

  /// What the layout places for [c]: the card itself, without its overhang.
  MasonryBox _boxOf(RenderBox c) {
    final span = (c.parentData! as MasonryData).span;
    return (height: span ? c.size.height : c.size.height - _overhang, span: span);
  }

  /// Where [boxes] rest in this grid, the columns inset by the overhang.
  List<Rect> _place(List<MasonryBox> boxes) => [
    for (final r in placeMasonry(boxes, _columns, columnWidth, _spacing)) r.shift(Offset(_overhang, 0)),
  ];

  @override
  bool get isRepaintBoundary => true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MasonryData) child.parentData = MasonryData();
  }

  Iterable<RenderBox> get _children sync* {
    var child = firstChild;
    while (child != null) {
      yield child;
      child = (child.parentData! as MasonryData).nextSibling;
    }
  }

  /// Every child's resting place, in order: for finding where a pointer is
  /// without chasing cards that are still moving. A card's is the card as
  /// drawn, not its box with the overhang.
  List<({RenderBox box, MasonryData data, Rect target})> get targets => [
    for (final c in _children) (box: c, data: c.parentData! as MasonryData, target: _restOf(c)),
  ];

  Rect _restOf(RenderBox c) {
    final d = c.parentData! as MasonryData;
    if (d.span) return d.target & c.size;
    final e = Offset(_overhang, _overhang);
    return (d.target + e) & (c.size - e as Size);
  }

  /// Where the children would rest in [order] (boxes of this grid).
  List<Rect> preview(List<RenderBox> order) => _place([for (final c in order) _boxOf(c)]);

  /// The width the grid is asked to fill, and the spring easing the width it
  /// lays out at ([_width]) toward it: a resize is not a jump. Cards stretch
  /// and slide with the easing width, and glide to their new places when it
  /// crosses into another column count.
  double _asked = -1;
  SpringSimulation? _widening;
  Duration _wideningStart = Duration.zero;

  @override
  void performLayout() {
    final asked = constraints.maxWidth;
    if (_width < 0 || !_animate) {
      _width = asked;
      _widening = null;
    } else if (asked != _asked) {
      // from where it is, at the speed it has: a resize in mid-ease, or a
      // window dragged wider, carries on smoothly. No overshoot: a card
      // should not poke past the grid's edge
      final v = _widening?.dx(_seconds(_now - _wideningStart)) ?? 0;
      _widening = SpringSimulation(Springs.standardDefaultEffects, _width, asked, v);
      _wideningStart = _now;
    }
    _asked = asked;
    final width = _width;
    final columns = columnsFor(width);
    // without motion, every card goes straight to its place; with it, a
    // card that changes column (or neighbor) springs there below, and one
    // that only stretches with the easing width follows it directly
    final snap = !_animate;
    _columns = columns;
    final colWidth = columnWidth;

    final kids = _children.toList();
    final e = _overhang;
    for (final c in kids) {
      final span = (c.parentData! as MasonryData).span;
      c.layout(BoxConstraints.tightFor(width: span ? width - e : colWidth + e), parentUsesSize: true);
    }
    final rects = _place([for (final c in kids) _boxOf(c)]);

    // who is above whom, per column, in the new layout
    final lastIn = <int, RenderBox>{};
    var bottom = 0.0;
    for (final (i, c) in kids.indexed) {
      final d = c.parentData! as MasonryData;
      final r = rects[i];
      bottom = math.max(bottom, r.bottom);
      final col = d.span ? -1 : ((r.left - e) / (colWidth + _spacing)).round();
      final above = d.span ? null : lastIn[col];
      if (!d.span) lastIn[col] = c;
      if (d.span) lastIn.clear();

      // a card's box starts up and left of the card, by the overhang
      final to = d.span ? r.topLeft : r.topLeft - Offset(e, e);
      if (!d.placed || snap) {
        // new here, or no motion: straight to its place
        d
          ..offset = to
          .._x = null
          .._y = null;
      } else if (to != d.target) {
        // a real move: a new column, or a new card above it (a reorder, an
        // insert, a removal); a card above changing size is not one
        final moved = col != d.column || !identical(above, d.above);
        if (moved || d.moving) {
          _springTo(d, to);
        } else {
          d.offset = to; // the same neighborhood: follow, don't fly
        }
      }
      d
        ..target = to
        ..placed = true
        ..column = col
        ..above = above;
    }
    size = constraints.constrain(Size(asked, bottom));
    if (_anyMoving || _widening != null) _ensureTicking();
  }

  void _springTo(MasonryData d, Offset to) {
    final t = _seconds(_now - d._start);
    final vx = d._x?.dx(t) ?? 0;
    final vy = d._y?.dx(t) ?? 0;
    d
      .._x = SpringSimulation(Springs.standardDefaultSpatial, d.offset.dx, to.dx, vx)
      .._y = SpringSimulation(Springs.standardDefaultSpatial, d.offset.dy, to.dy, vy)
      .._start = _now;
  }

  static double _seconds(Duration d) => d.inMicroseconds / Duration.microsecondsPerSecond;

  bool get _anyMoving => _children.any((c) => (c.parentData! as MasonryData).moving);

  void _ensureTicking() {
    if (!attached) return;
    final ticker = _ticker ??= _vsync.createTicker(_tick);
    if (!ticker.isActive) {
      // springs measure time from the ticker's start
      _now = Duration.zero;
      for (final c in _children) {
        (c.parentData! as MasonryData)._start = Duration.zero;
      }
      _wideningStart = Duration.zero;
      ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    _now = elapsed;
    var active = false;
    if (_widening case final w?) {
      final t = _seconds(elapsed - _wideningStart);
      if (w.isDone(t)) {
        _width = _asked;
        _widening = null;
      } else {
        _width = w.x(t);
        active = true;
      }
      markNeedsLayout();
    }
    for (final c in _children) {
      final d = c.parentData! as MasonryData;
      final x = d._x, y = d._y;
      if (x == null || y == null) continue;
      final t = _seconds(elapsed - d._start);
      if (x.isDone(t) && y.isDone(t)) {
        d
          ..offset = d.target
          .._x = null
          .._y = null;
      } else {
        d.offset = Offset(x.x(t), y.x(t));
        active = true;
      }
    }
    markNeedsPaint();
    if (!active) {
      _ticker?.stop();
      markNeedsSemanticsUpdate();
    }
  }

  void _settleAll() {
    if (_widening != null) {
      _widening = null;
      _width = _asked;
      markNeedsLayout();
    }
    for (final c in _children) {
      final d = c.parentData! as MasonryData;
      d
        ..offset = d.target
        .._x = null
        .._y = null;
    }
    _ticker?.stop();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (_anyMoving || _widening != null) _ensureTicking();
  }

  @override
  void detach() {
    _ticker?.stop();
    super.detach();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
