import 'package:chit/ui/masonry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A board of [ids] in a 400-wide grid of two 196-wide columns.
Widget board(
  List<String> ids, {
  Map<String, double> heights = const {},
  bool still = false,
  List<String> spans = const [],
}) => MediaQuery(
  data: MediaQueryData(disableAnimations: still),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        child: Masonry(
          minColumnWidth: 180,
          spacing: 8,
          children: [
            for (final id in ids)
              MasonryChild(
                key: ValueKey(id),
                tag: id,
                span: spans.contains(id),
                child: GestureDetector(
                  onTap: () => tapped.add(id),
                  child: SizedBox(height: heights[id] ?? 100, child: Text(id)),
                ),
              ),
          ],
        ),
      ),
    ),
  ),
);

final tapped = <String>[];

Offset at(WidgetTester t, String id) => t.getTopLeft(find.text(id));

void main() {
  setUp(tapped.clear);

  test('placement: shortest column, headers restart the columns', () {
    final rects = placeMasonry(
      [(height: 100, span: false), (height: 50, span: false), (height: 30, span: true), (height: 10, span: false)],
      2,
      196,
      8,
    );
    expect(rects[0], const Rect.fromLTWH(0, 0, 196, 100));
    expect(rects[1], const Rect.fromLTWH(204, 0, 196, 50));
    // the header starts below the tallest column, full width
    expect(rects[2], const Rect.fromLTWH(0, 100, 400, 30));
    expect(rects[3], const Rect.fromLTWH(0, 130, 196, 10));
  });

  testWidgets('a first layout does not move', (t) async {
    await t.pumpWidget(board(['a', 'b', 'c']));
    expect(at(t, 'a'), Offset.zero);
    expect(at(t, 'b'), const Offset(204, 0));
    expect(t.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a reorder glides each card to its new place', (t) async {
    await t.pumpWidget(board(['a', 'b', 'c']));
    final from = at(t, 'c'); // (0, 108)
    await t.pumpWidget(board(['c', 'a', 'b']));
    await t.pump(const Duration(milliseconds: 50));
    final mid = at(t, 'c');
    expect(mid.dy, lessThan(from.dy));
    expect(mid.dy, greaterThan(0));
    await t.pumpAndSettle();
    expect(at(t, 'c'), Offset.zero);
    expect(at(t, 'a'), const Offset(204, 0));
  });

  testWidgets('a new card appears in place', (t) async {
    await t.pumpWidget(board(['a', 'b']));
    await t.pumpWidget(board(['a', 'b', 'n']));
    expect(at(t, 'n'), const Offset(0, 108));
  });

  testWidgets('reduced motion snaps', (t) async {
    await t.pumpWidget(board(['a', 'b', 'c'], still: true));
    await t.pumpWidget(board(['c', 'a', 'b'], still: true));
    await t.pump();
    expect(at(t, 'c'), Offset.zero);
  });

  testWidgets('a card growing moves the one below it directly, no spring', (t) async {
    // b is tall, so c stays under a in the first column
    await t.pumpWidget(board(['a', 'b', 'c'], heights: {'b': 300}));
    expect(at(t, 'c'), const Offset(0, 108));
    await t.pumpWidget(board(['a', 'b', 'c'], heights: {'a': 140, 'b': 300}));
    await t.pump();
    expect(at(t, 'c'), const Offset(0, 148));
  });

  testWidgets('a tap lands on a card where it is drawn, mid-flight', (t) async {
    await t.pumpWidget(board(['a', 'b', 'c']));
    await t.pumpWidget(board(['c', 'a', 'b']));
    await t.pump(const Duration(milliseconds: 40));
    await t.tapAt(at(t, 'c') + const Offset(10, 10));
    expect(tapped, ['c']);
  });

  testWidgets('headers span the width', (t) async {
    await t.pumpWidget(board(['H', 'a', 'b'], spans: ['H'], heights: {'H': 30}));
    expect(t.getSize(find.text('H')).width, 400);
    expect(at(t, 'a'), const Offset(0, 30));
  });
}
