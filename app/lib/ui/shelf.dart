/// What the board shows: the shelves, the chips that narrow them, and the
/// pure work of picking, ordering and sectioning a shelf's notes. Kept out
/// of the widgets so it can be tested and its result kept between builds.
library;

import 'package:material_ui/material_ui.dart';

import '../core/board_order.dart';
import '../core/protocol.dart';
import '../core/reminders.dart';
import '../data/replica.dart';

/// What the chips under the search bar narrow a shelf to (labels are
/// chips there too; those pick the label's own shelf).
enum NoteFilter {
  lists('Lists'),
  images('Images'),
  shared('Shared');

  const NoteFilter(this.label);
  final String label;
}

enum Shelf {
  notes('Notes', Icons.lightbulb_outline, Icons.lightbulb),
  reminders('Reminders', Icons.notifications_none, Icons.notifications),
  labeled('Label', Icons.label_outline, Icons.label),
  archive('Archive', Icons.archive_outlined, Icons.archive),
  trash('Trash', Icons.delete_outline, Icons.delete);

  const Shelf(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Which notes a shelf shows and how: the shelf (and its label), the words
/// searched for, the chips on, and who is looking.
typedef ShelfQuery = ({Shelf shelf, String? label, String query, Set<NoteFilter> filters, String me});

/// A shelf's notes in two sections with their headers: pinned and the rest;
/// on Reminders, what is still to come (soonest first) and what has passed
/// (latest first); archive and trash in one.
typedef ShelfView = ({List<Note> shown, List<Note> first, List<Note> second, String firstLabel, String secondLabel});

/// The notes [q] picks from [lib], in order, in their sections.
ShelfView shelfView(Library lib, ShelfQuery q, {DateTime? now}) {
  // each word searched for must be somewhere on the note (its title,
  // text, items or labels), in any order: "grocery milk" finds the
  // Groceries list with milk on it
  final words = q.query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final searching = words.isNotEmpty;
  bool hit(Note n) {
    if (!searching) return true;
    final text = [
      n.title,
      n.body,
      for (final l in lib.labelsOf(n.id)) l.name,
      for (final i in lib.items[n.id] ?? const <Item>[]) i.text,
    ].join('\n').toLowerCase();
    return words.every(text.contains);
  }

  // every chip that is on has to hold
  bool passes(Note n) => q.filters.every(
    (f) => switch (f) {
      NoteFilter.lists => n.isList,
      NoteFilter.images => (lib.attachments[n.id] ?? const <Attachment>[]).any((a) => a.isImage),
      NoteFilter.shared => n.owner != q.me || (lib.members[n.id]?.isNotEmpty ?? false),
    },
  );
  // a reminder's time, parsed once per note rather than per comparison
  final due = <String, DateTime?>{};
  DateTime? dueOf(Note n) => due.putIfAbsent(n.id, () => reminderTime(lib.stateOf(n.id).reminder));
  bool onShelf(Note n) {
    final st = lib.stateOf(n.id);
    return switch (q.shelf) {
      Shelf.trash => n.trashed.isNotEmpty,
      Shelf.archive => st.archived && n.trashed.isEmpty,
      // a search from Notes reaches the archive too
      Shelf.notes => n.trashed.isEmpty && (!st.archived || searching),
      Shelf.reminders => n.trashed.isEmpty && !st.reminderDone && dueOf(n) != null,
      // a label finds its notes wherever they are, short of the trash
      Shelf.labeled => n.trashed.isEmpty && st.labels.contains(q.label),
    };
  }

  // Notes and labels in board order (where you put them; new notes on
  // top); Reminders soonest first; archive and trash newest made first.
  // Editing never moves a note.
  final shown = lib.notes.where((n) => onShelf(n) && hit(n) && passes(n)).toList();
  switch (q.shelf) {
    case Shelf.notes when searching:
      // what was found: the notes, then what is archived
      shown.sort((a, b) => boardCompare(a, b, lib.stateOf(a.id), lib.stateOf(b.id)));
      return (
        shown: shown,
        first: [
          for (final n in shown)
            if (!lib.stateOf(n.id).archived) n,
        ],
        second: [
          for (final n in shown)
            if (lib.stateOf(n.id).archived) n,
        ],
        firstLabel: 'Notes',
        secondLabel: 'Archive',
      );
    case Shelf.notes || Shelf.labeled:
      shown.sort((a, b) => boardCompare(a, b, lib.stateOf(a.id), lib.stateOf(b.id)));
      final pinned = [
        for (final n in shown)
          if (lib.stateOf(n.id).pinned) n,
      ];
      final others = [
        for (final n in shown)
          if (!lib.stateOf(n.id).pinned) n,
      ];
      return (shown: shown, first: pinned, second: others, firstLabel: 'Pinned', secondLabel: 'Others');
    case Shelf.reminders:
      shown.sort((a, b) => dueOf(a)!.compareTo(dueOf(b)!));
      final at = now ?? DateTime.now();
      return (
        shown: shown,
        first: [
          for (final n in shown)
            if (dueOf(n)!.isAfter(at)) n,
        ],
        second: [
          for (final n in shown.reversed)
            if (!dueOf(n)!.isAfter(at)) n,
        ],
        firstLabel: 'Upcoming',
        secondLabel: 'Earlier',
      );
    case Shelf.archive || Shelf.trash:
      shown.sort((a, b) => b.created.compareTo(a.created) != 0 ? b.created.compareTo(a.created) : b.id.compareTo(a.id));
      return (shown: shown, first: const [], second: shown, firstLabel: '', secondLabel: '');
  }
}

/// [shelfView], kept between builds: worked out again only when the
/// library or the question changes, not for a hover, a selection or a
/// drag frame.
final class ShelfMemo {
  Library? _lib;
  ShelfQuery? _q;
  String _filters = '';
  ShelfView? _view;
  DateTime _at = DateTime(0);

  ShelfView of(Library lib, ShelfQuery q) {
    final filters = (q.filters.map((f) => f.index).toList()..sort()).join(',');
    final same =
        identical(lib, _lib) &&
        _q != null &&
        _q!.shelf == q.shelf &&
        _q!.label == q.label &&
        _q!.query == q.query &&
        _q!.me == q.me &&
        filters == _filters &&
        // reminders move from Upcoming to Earlier as time passes
        (q.shelf != Shelf.reminders || DateTime.now().difference(_at) < const Duration(seconds: 30));
    if (!same) {
      _lib = lib;
      _q = q;
      _filters = filters;
      _at = DateTime.now();
      _view = shelfView(lib, q, now: _at);
    }
    return _view!;
  }
}
