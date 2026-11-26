import 'package:chit/ui/check_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a folding row shrinks away, then says it is gone', (tester) async {
    var gone = 0;
    Widget row(bool leaving) => MaterialApp(
      home: Column(
        children: [
          Fold(
            leaving: leaving,
            onGone: () => gone++,
            child: const SizedBox(height: 40, child: Text('milk')),
          ),
        ],
      ),
    );
    await tester.pumpWidget(row(false));
    expect(tester.getSize(find.byType(Fold)).height, 40);

    await tester.pumpWidget(row(true));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = tester.getSize(find.byType(Fold)).height;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(40));
    expect(gone, 0);

    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Fold)).height, 0);
    expect(gone, 1);
  });

  testWidgets('an arriving row unfolds to its full height', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(children: [Fold(enter: true, child: SizedBox(height: 40))]),
      ),
    );
    expect(tester.getSize(find.byType(Fold)).height, 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Fold)).height, 40);
  });

  testWidgets('check-off shows the check, folds after the beat, and commits once', (tester) async {
    var refreshes = 0;
    var commits = 0;
    final off = CheckOff(() => refreshes++);
    await tester.pumpWidget(const SizedBox());

    off.start('milk', target: true, still: false, commit: () => commits++);
    expect(off.showsChecked('milk'), isTrue);
    expect(off.isLeaving('milk'), isFalse);
    expect(commits, 0);

    // a second tap during the beat does nothing
    off.start('milk', target: true, still: false, commit: () => commits++);

    await tester.pump(checkBeat);
    expect(off.isLeaving('milk'), isTrue);
    expect(commits, 0);

    off.gone('milk');
    expect(commits, 1);
    expect(off.showsChecked('milk'), isFalse);
    // it folds in once it reaches the checked list, and only there
    expect(off.takeArrival('milk', false), isFalse);
    expect(off.takeArrival('milk', true), isTrue);
    expect(off.takeArrival('milk', true), isFalse);
    expect(refreshes, greaterThan(0));
  });

  testWidgets('with reduced motion a check commits at once', (tester) async {
    var commits = 0;
    final off = CheckOff(() {});
    off.start('eggs', target: true, still: true, commit: () => commits++);
    expect(commits, 1);
    expect(off.showsChecked('eggs'), isFalse);
  });

  testWidgets('closing the page mid-check still sends it', (tester) async {
    var commits = 0;
    final off = CheckOff(() {});
    await tester.pumpWidget(const SizedBox());
    off.start('bread', target: true, still: false, commit: () => commits++);
    off.flush();
    expect(commits, 1);
    await tester.pump(checkBeat);
    expect(commits, 1);
  });
}
