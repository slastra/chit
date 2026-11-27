/// Checklist edits worked out as data: where a moved item goes. Pure, for
/// the editor and tests.
library;

import 'board_order.dart' show orderSpread;
import 'order.dart';
import 'protocol.dart';

/// The order keys to write when the item at [from] in [items] (in order)
/// moves to [to] (its index once moved). Usually one key, between its new
/// neighbors; if their keys leave no room (equal, or broken), the whole list
/// gets fresh keys.
Map<String, String> moveItem(List<Item> items, int from, int to) {
  if (from == to || from < 0 || from >= items.length) return const {};
  final rest = [...items]..removeAt(from);
  final at = to.clamp(0, rest.length);
  final moved = items[from];
  final before = at > 0 ? rest[at - 1].order : '';
  final after = at < rest.length ? rest[at].order : '';
  final roomy =
      (before.isEmpty || isValidOrderKey(before)) &&
      (after.isEmpty || isValidOrderKey(after)) &&
      (before.isEmpty || after.isEmpty || before.compareTo(after) < 0);
  if (roomy) {
    return {moved.id: after.isEmpty ? orderAfter(before) : orderBetween(before, after)};
  }
  final placed = [...rest]..insert(at, moved);
  final keys = orderSpread('', '', placed.length);
  return {
    for (final (i, it) in placed.indexed)
      if (it.order != keys[i]) it.id: keys[i],
  };
}
