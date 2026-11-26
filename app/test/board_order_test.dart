import 'package:chit/core/board_order.dart';
import 'package:chit/core/order.dart';
import 'package:chit/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Note note(String id, String created) => Note({'id': id, 'created': created});
NoteState state(String id, {bool pinned = false, String order = ''}) =>
    NoteState({'note': id, 'pinned': pinned, 'order': order});

void main() {
  test('board order matches Go (internal/notes/board_test.go)', () {
    final ns = [
      note('a', '2026-11-01'),
      note('b', '2026-11-02'),
      note('c', '2026-11-03'),
      note('d', '2026-11-04'),
      note('e', '2026-11-05'),
      note('f', '2026-11-05'),
    ];
    final st = {
      'a': state('a', order: 'V'),
      'b': state('b', order: '1'),
      'c': state('c', order: 'bad0'),
      'd': state('d', pinned: true, order: 'k'),
      'e': state('e'),
      'f': state('f'),
    };
    ns.sort((x, y) => boardCompare(x, y, st[x.id]!, st[y.id]!));
    expect(ns.map((n) => n.id).join(' '), 'd f e c b a');
  });

  test('orderSpread gives ordered, valid, short keys', () {
    for (final (a, b) in [('', ''), ('', 'V'), ('1', '2'), ('V', ''), ('a', 'b')]) {
      for (final n in [1, 2, 5, 40]) {
        final keys = orderSpread(a, b, n);
        expect(keys, hasLength(n));
        for (final (i, k) in keys.indexed) {
          expect(isValidOrderKey(k), isTrue, reason: k);
          expect(k.compareTo(a), greaterThan(0));
          if (b.isNotEmpty) expect(k.compareTo(b), lessThan(0));
          if (i > 0) expect(k.compareTo(keys[i - 1]), greaterThan(0));
          expect(k.length, lessThanOrEqualTo(8));
        }
      }
    }
  });

  group('planMove', () {
    // a board: x, y with no place yet (newest first), then placed p1 < p2
    final section = [note('x', '5'), note('y', '4'), note('p1', '1'), note('p2', '2')];
    final st = {
      'x': state('x'),
      'y': state('y'),
      'p1': state('p1', order: 'V'),
      'p2': state('p2', order: 'k'),
      'm': state('m', order: 'z'),
    };
    List<String> board(List<StateOp> ops) {
      final next = {for (final e in st.entries) e.key: Map<String, Object?>.of(st[e.key]!.json)};
      for (final o in ops) {
        next[o.note]![o.field] = o.value;
      }
      final all = [...section, note('m', '3')];
      all.sort((a, b) => boardCompare(a, b, NoteState(next[a.id]!), NoteState(next[b.id]!)));
      return all.map((n) => n.id).toList();
    }

    test('between two placed notes: one key', () {
      final ops = planMove(section: section, states: st, moved: 'm', index: 3, toPinned: false, wasPinned: false);
      expect(ops, hasLength(1));
      expect(board(ops), ['x', 'y', 'p1', 'm', 'p2']);
    });

    test('at the end: one key after the last', () {
      final ops = planMove(section: section, states: st, moved: 'm', index: 4, toPinned: false, wasPinned: false);
      expect(ops, hasLength(1));
      expect(board(ops), ['x', 'y', 'p1', 'p2', 'm']);
    });

    test('among the unplaced: the prefix and the note get keys, nothing else', () {
      final ops = planMove(section: section, states: st, moved: 'm', index: 1, toPinned: false, wasPinned: false);
      expect(ops.map((o) => o.note).toSet(), {'x', 'm', 'y'});
      expect(board(ops), ['x', 'm', 'y', 'p1', 'p2']);
    });

    test('into the other section: pins too', () {
      final ops = planMove(section: section, states: st, moved: 'm', index: 2, toPinned: true, wasPinned: false);
      expect(ops.first, (note: 'm', field: 'pinned', value: true));
    });

    test('equal neighbor keys: the section is spaced out afresh', () {
      final clash = {...st, 'p1': state('p1', order: 'k')};
      final ops = planMove(section: section, states: clash, moved: 'm', index: 3, toPinned: false, wasPinned: false);
      expect(ops.length, 5);
      final keys = [for (final o in ops) o.value as String];
      expect([...keys]..sort(), keys);
    });

    test('into an empty section', () {
      final ops = planMove(section: const [], states: st, moved: 'm', index: 0, toPinned: true, wasPinned: false);
      expect(ops.map((o) => o.field), ['pinned', 'order']);
    });
  });
}
