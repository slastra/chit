import 'package:chit/ui/board_drag.dart';
import 'package:chit/ui/masonry.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A one-column board of notes a..d (100 tall, 12 apart), all in Others,
/// previewing a drag the way the home page does.
class TestBoard extends StatefulWidget {
  const TestBoard({super.key, required this.drops, required this.taps});
  final List<(String, Anchor)> drops;
  final List<String> taps;

  @override
  State<TestBoard> createState() => _TestBoardState();
}

class _TestBoardState extends State<TestBoard> {
  final gridKey = GlobalKey();
  List<String> others = ['a', 'b', 'c', 'd'];
  late final drag = BoardDrag(
    gridKey: gridKey,
    cardFor: (id) => SizedBox(height: 100, child: Text('lifted $id')),
    onDrop: (id, a) {
      widget.drops.add((id, a));
      setState(() {
        others.remove(id);
        final at = a.before == null ? -1 : others.indexOf(a.before!);
        others.insert(at < 0 ? others.length : at, id);
      });
    },
  )..addListener(() => setState(() {}));

  @override
  void dispose() {
    drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var shown = others;
    if (drag.id case final id? when drag.anchor != null) {
      shown = [...others]..remove(id);
      final a = drag.anchor!;
      final at = a.before == null ? -1 : shown.indexOf(a.before!);
      shown.insert(at < 0 ? shown.length : at, id);
    }
    drag.sections = (pinned: const [], others: shown);
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 200,
        child: BoardGestures(
          drag: drag,
          enabled: true,
          child: Masonry(
            key: gridKey,
            minColumnWidth: 180,
            spacing: 12,
            children: [
              for (final id in shown)
                MasonryChild(
                  key: ValueKey(id),
                  tag: id,
                  child: GestureDetector(
                    onTap: () => widget.taps.add(id),
                    child: SizedBox(height: 100, child: Text(id)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

void main() {
  late List<(String, Anchor)> drops;
  late List<String> taps;

  Future<void> pumpBoard(WidgetTester t) async {
    drops = [];
    taps = [];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestBoard(drops: drops, taps: taps),
        ),
      ),
    );
  }

  // centers of a..d: y = 50, 162, 274, 386
  testWidgets('a mouse drag moves a note, and the others make room', (t) async {
    await pumpBoard(t);
    final g = await t.startGesture(const Offset(100, 50), kind: PointerDeviceKind.mouse);
    for (var y = 50.0; y <= 300; y += 10) {
      await g.moveTo(Offset(100, y));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('lifted a'), findsOneWidget);
    await g.up();
    await t.pumpAndSettle();
    expect(drops, hasLength(1));
    expect(drops.single.$1, 'a');
    expect(drops.single.$2.pinned, isFalse);
    // it landed below c
    expect(t.getTopLeft(find.text('a')).dy, greaterThan(t.getTopLeft(find.text('c')).dy));
    expect(find.text('lifted a'), findsNothing);
  });

  testWidgets('a click still opens a note', (t) async {
    await pumpBoard(t);
    await t.tapAt(const Offset(100, 162), kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();
    expect(taps, ['b']);
    expect(drops, isEmpty);
  });

  testWidgets('a touch drags after a long press', (t) async {
    await pumpBoard(t);
    final g = await t.startGesture(const Offset(100, 386));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var y = 386.0; y >= 30; y -= 10) {
      await g.moveTo(Offset(100, y));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();
    expect(drops.single.$1, 'd');
    expect(drops.single.$2.before, 'a');
  });

  testWidgets('a touch that moves at once does not drag', (t) async {
    await pumpBoard(t);
    final g = await t.startGesture(const Offset(100, 50));
    await g.moveTo(const Offset(100, 200));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await t.pumpAndSettle();
    expect(drops, isEmpty);
    expect(find.text('lifted a'), findsNothing);
  });

  testWidgets('Escape puts the note back', (t) async {
    await pumpBoard(t);
    final g = await t.startGesture(const Offset(100, 50), kind: PointerDeviceKind.mouse);
    for (var y = 50.0; y <= 300; y += 10) {
      await g.moveTo(Offset(100, y));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await g.up();
    await t.pumpAndSettle();
    expect(drops, isEmpty);
    expect(t.getTopLeft(find.text('a')).dy, 0);
  });
}
