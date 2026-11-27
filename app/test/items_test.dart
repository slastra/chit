import 'package:chit/core/items.dart';
import 'package:chit/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Item item(String id, String order) => Item({'id': id, 'note': 'n', 'text': id, 'order': order});

List<String> after(List<Item> items, Map<String, String> keys) {
  final moved = [for (final it in items) (id: it.id, order: keys[it.id] ?? it.order)]
    ..sort((a, b) => a.order.compareTo(b.order));
  return [for (final m in moved) m.id];
}

void main() {
  final list = [item('a', 'V'), item('b', 'X'), item('c', 'Z')];

  test('moving down writes one key, between its new neighbors', () {
    final keys = moveItem(list, 0, 1);
    expect(keys.keys, ['a']);
    expect(after(list, keys), ['b', 'a', 'c']);
  });

  test('to the end and to the top', () {
    expect(after(list, moveItem(list, 0, 2)), ['b', 'c', 'a']);
    expect(after(list, moveItem(list, 2, 0)), ['c', 'a', 'b']);
  });

  test('neighbors with no room between them get fresh keys', () {
    final tied = [item('a', 'V'), item('b', 'V'), item('c', 'V')];
    final keys = moveItem(tied, 2, 1);
    expect(after(tied, keys), ['a', 'c', 'b']);
  });

  test('nowhere to go is nothing to write', () {
    expect(moveItem(list, 1, 1), isEmpty);
  });
}
