/// Where notes sit on a person's board, and the edits that move one.
/// Pure: the board widgets and their tests share it. The same order as
/// chit's internal/notes.BoardBefore, so lastshell and `chit ls` agree.
library;

import 'order.dart';
import 'protocol.dart';

/// A note's place on the board: its order key, or "" for no place yet (a
/// missing or broken key alike).
String boardKey(NoteState st) => _keys[st] ??= isValidOrderKey(st.order) ? st.order : '';

/// Each state's checked key, worked out once: a sort compares each note
/// many times.
final _keys = Expando<String>('boardKey');

/// Board order: pinned first; within a section, notes with no place yet on
/// top, newest first; then the placed ones by key (byte order, as Go's).
int boardCompare(Note a, Note b, NoteState sa, NoteState sb) {
  if (sa.pinned != sb.pinned) return sa.pinned ? -1 : 1;
  final ka = boardKey(sa), kb = boardKey(sb);
  if (ka.isEmpty != kb.isEmpty) return ka.isEmpty ? -1 : 1;
  if (ka != kb) return ka.compareTo(kb);
  if (a.created != b.created) return b.created.compareTo(a.created);
  return b.id.compareTo(a.id);
}

/// [n] ordered keys strictly between [a] and [b] ("" for either end),
/// kept short: bisected between two bounds, stepped after an open end.
List<String> orderSpread(String a, String b, int n) {
  if (n <= 0) return const [];
  if (b.isEmpty) {
    final keys = <String>[];
    var k = a;
    for (var i = 0; i < n; i++) {
      k = orderAfter(k);
      keys.add(k);
    }
    return keys;
  }
  final mid = orderBetween(a, b);
  final left = orderSpread(a, mid, (n - 1) ~/ 2);
  final right = orderSpread(mid, b, n - 1 - left.length);
  return [...left, mid, ...right];
}

/// Keys get no longer than this before a section is spaced out afresh.
const _longestKey = 10;

/// One edit for [move]: a note's state field.
typedef StateOp = ({String note, String field, Object? value});

/// The edits that put [moved] at [index] of [section] (the destination
/// section's notes in board order, without [moved]); [toPinned] is the
/// section's kind, [wasPinned] where the note came from.
///
/// Usually one key between the new neighbors. Notes with no place yet are
/// always a prefix of a section; when the drop lands among them, that
/// prefix (and the note) get keys before the first placed note. When the
/// neighbors' keys leave no room (two devices made the same key) or keys
/// grow long, the whole section is spaced out afresh.
List<StateOp> planMove({
  required List<Note> section,
  required Map<String, NoteState> states,
  required String moved,
  required int index,
  required bool toPinned,
  required bool wasPinned,
}) {
  final at = index.clamp(0, section.length);
  String key(Note n) => boardKey(states[n.id] ?? NoteState({'note': n.id}));
  final ops = <StateOp>[if (toPinned != wasPinned) (note: moved, field: 'pinned', value: toPinned)];

  final prefix = section.takeWhile((n) => key(n).isEmpty).length;
  final ids = [...section.map((n) => n.id)]..insert(at, moved);

  void respace(List<String> which, List<String> keys) {
    for (final (i, id) in which.indexed) {
      ops.add((note: id, field: 'order', value: keys[i]));
    }
  }

  if (at <= prefix) {
    // among the unplaced: place them, and the note, before the first placed
    final head = ids.sublist(0, prefix + 1);
    final firstPlaced = prefix < section.length ? key(section[prefix]) : '';
    respace(head, orderSpread('', firstPlaced, head.length));
    return ops;
  }
  final prev = key(section[at - 1]);
  final next = at < section.length ? key(section[at]) : '';
  if (next.isEmpty || prev.compareTo(next) < 0) {
    final k = orderBetween(prev, next);
    if (k.length <= _longestKey) {
      ops.add((note: moved, field: 'order', value: k));
      return ops;
    }
  }
  respace(ids, orderSpread('', '', ids.length));
  return ops;
}
