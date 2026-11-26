import 'dart:math';

import 'package:chit/core/hlc.dart';
import 'package:chit/core/order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hlc', () {
    test('increases within one millisecond', () {
      final c = HlcClock('dev1', now: () => DateTime.fromMillisecondsSinceEpoch(1795651200000));
      var prev = '';
      for (var i = 0; i < 1000; i++) {
        final h = c.now();
        expect(isValidHlc(h), isTrue);
        expect(h.compareTo(prev), greaterThan(0));
        prev = h;
      }
    });

    test('survives the wall clock stepping back', () {
      var ms = 1795651200500;
      final c = HlcClock('dev1', now: () => DateTime.fromMillisecondsSinceEpoch(ms));
      final a = c.now();
      ms = 1795651200000;
      expect(c.now().compareTo(a), greaterThan(0));
    });

    test('orders after an observed remote clock', () {
      final c = HlcClock('slow', now: () => DateTime.fromMillisecondsSinceEpoch(1795651200000));
      const remote = '1795651299999-0007-fast';
      c.observe(remote);
      expect(c.now().compareTo(remote), greaterThan(0));
    });

    test('matches the Go format byte for byte', () {
      final c = HlcClock('desk', now: () => DateTime.fromMillisecondsSinceEpoch(1795651200000));
      expect(c.now(), '1795651200000-0000-desk');
      expect(c.now(), '1795651200000-0001-desk');
    });
  });

  group('order', () {
    test('appends stay ordered and short', () {
      var k = '';
      for (var i = 0; i < 1000; i++) {
        final next = orderAfter(k);
        expect(isValidOrderKey(next), isTrue);
        expect(next.compareTo(k), greaterThan(0));
        k = next;
      }
      expect(k.length, lessThanOrEqualTo(20));
    });

    test('random inserts keep order', () {
      final r = Random(1);
      final keys = [orderAfter('')];
      for (var i = 0; i < 2000; i++) {
        final at = r.nextInt(keys.length + 1);
        final a = at > 0 ? keys[at - 1] : '';
        final b = at < keys.length ? keys[at] : '';
        final k = orderBetween(a, b);
        expect(isValidOrderKey(k), isTrue, reason: 'between($a, $b) = $k');
        if (a.isNotEmpty) expect(k.compareTo(a), greaterThan(0));
        if (b.isNotEmpty) expect(k.compareTo(b), lessThan(0));
        keys.insert(at, k);
      }
    });

    test('agrees with the Go implementation on known cases', () {
      // Values computed by chit's internal/order.
      expect(orderAfter(''), '1');
      expect(orderAfter('z'), 'z1');
      expect(orderBetween('', '1'), '0V');
      expect(orderBetween('a', 'b'), 'aV');
    });
  });
}
