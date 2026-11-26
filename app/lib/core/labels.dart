/// Labels: names as people type them, and what turning one on or off does
/// to a set of notes (the editor's picker, the board's selection).
library;

import 'protocol.dart';

/// A label name as kept: trimmed, inner runs of space made one.
String labelName(String typed) => typed.trim().replaceAll(RegExp(r'\s+'), ' ');

/// The label already called [name], ignoring case and spacing.
Label? labelNamed(List<Label> labels, String name) {
  final want = labelName(name).toLowerCase();
  if (want.isEmpty) return null;
  for (final l in labels) {
    if (labelName(l.name).toLowerCase() == want) return l;
  }
  return null;
}

/// Whether [label] is on all of the notes (true), none (false), or some
/// (null): a checkbox over a selection.
bool? labelState(Iterable<List<String>> notes, String label) {
  var all = true, any = false;
  for (final ids in notes) {
    final has = ids.contains(label);
    all &= has;
    any |= has;
  }
  return all ? true : (any ? null : false);
}

/// Each note's new label list with [label] turned [on]; notes already that
/// way are left out, so nothing is sent for them.
Map<String, List<String>> toggleLabel(Map<String, List<String>> notes, String label, {required bool on}) => {
  for (final MapEntry(key: note, value: ids) in notes.entries)
    if (ids.contains(label) != on) note: on ? [...ids, label] : [...ids.where((i) => i != label)],
};
