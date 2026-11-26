import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Cards in columns, each placed in whichever column is shortest so far by
/// its real height: the Keep layout. Lays out every child (fine at a
/// household's scale); put it in a scroll view.
class Masonry extends MultiChildRenderObjectWidget {
  const Masonry({super.key, required this.minColumnWidth, this.spacing = 8, super.children});

  final double minColumnWidth;
  final double spacing;

  @override
  RenderMasonry createRenderObject(BuildContext context) =>
      RenderMasonry(minColumnWidth: minColumnWidth, spacing: spacing);

  @override
  void updateRenderObject(BuildContext context, RenderMasonry renderObject) => renderObject
    ..minColumnWidth = minColumnWidth
    ..spacing = spacing;
}

class _MasonryData extends ContainerBoxParentData<RenderBox> {}

class RenderMasonry extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _MasonryData>, RenderBoxContainerDefaultsMixin<RenderBox, _MasonryData> {
  // private named parameters: callers still write minColumnWidth: and spacing:
  RenderMasonry({required this._minColumnWidth, required this._spacing});

  double _minColumnWidth;
  set minColumnWidth(double v) {
    if (v == _minColumnWidth) return;
    _minColumnWidth = v;
    markNeedsLayout();
  }

  double _spacing;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  /// How many columns fit [width].
  int columnsFor(double width) => math.max(1, ((width + _spacing) / (_minColumnWidth + _spacing)).floor());

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MasonryData) child.parentData = _MasonryData();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final columns = columnsFor(width);
    final colWidth = (width - _spacing * (columns - 1)) / columns;
    final tops = List<double>.filled(columns, 0);
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tightFor(width: colWidth), parentUsesSize: true);
      var col = 0;
      for (var c = 1; c < columns; c++) {
        if (tops[c] < tops[col] - 0.5) col = c;
      }
      final data = child.parentData! as _MasonryData;
      data.offset = Offset(col * (colWidth + _spacing), tops[col]);
      tops[col] += child.size.height + _spacing;
      child = data.nextSibling;
    }
    final height = childCount == 0 ? 0.0 : math.max(0.0, tops.reduce(math.max) - _spacing);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
