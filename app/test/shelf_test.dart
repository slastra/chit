import 'package:chit/core/protocol.dart';
import 'package:chit/data/replica.dart';
import 'package:chit/ui/shelf.dart';
import 'package:flutter_test/flutter_test.dart';

const me = 'me0000000000001';

Library library() => Library(
  notes: [
    Note({'id': 'a', 'owner': me, 'title': 'Groceries', 'kind': 'list', 'created': '2026-11-01'}),
    Note({'id': 'b', 'owner': me, 'title': 'Trip', 'body': 'Hot Springs', 'created': '2026-11-02'}),
    Note({'id': 'c', 'owner': 'someone', 'title': 'Shared plan', 'created': '2026-11-03'}),
    Note({'id': 'd', 'owner': me, 'title': 'Old', 'created': '2026-11-04', 'trashed': '2026-11-05'}),
  ],
  items: {
    'a': [
      Item({'id': 'i1', 'note': 'a', 'text': 'milk'}),
    ],
  },
  members: const {},
  states: {
    'b': NoteState({'note': 'b', 'pinned': true, 'reminder': '2026-12-01T09:00:00Z'}),
    'c': NoteState({'note': 'c', 'reminder': '2026-11-10T09:00:00Z'}),
  },
  attachments: const {},
);

ShelfQuery q(Shelf shelf, {String query = '', Set<NoteFilter> filters = const {}}) =>
    (shelf: shelf, label: null, query: query, filters: filters, me: me);

void main() {
  test('Notes: pinned first, the rest newest first, trash left out', () {
    final v = shelfView(library(), q(Shelf.notes));
    expect([for (final n in v.first) n.id], ['b']);
    expect([for (final n in v.second) n.id], ['c', 'a']);
    expect(v.firstLabel, 'Pinned');
  });

  test('search reaches items, chips narrow', () {
    expect([for (final n in shelfView(library(), q(Shelf.notes, query: 'MILK')).shown) n.id], ['a']);
    expect(
      [
        for (final n in shelfView(library(), q(Shelf.notes, filters: {NoteFilter.lists})).shown) n.id,
      ],
      ['a'],
    );
    expect(
      [
        for (final n in shelfView(library(), q(Shelf.notes, filters: {NoteFilter.shared})).shown) n.id,
      ],
      ['c'],
    );
  });

  test('every word must match, anywhere on the note', () {
    expect([for (final n in shelfView(library(), q(Shelf.notes, query: 'groceries milk')).shown) n.id], ['a']);
    expect(shelfView(library(), q(Shelf.notes, query: 'groceries springs')).shown, isEmpty);
  });

  test('a search from Notes reaches the archive, under its own heading', () {
    final lib = Library(
      notes: [
        Note({'id': 'x', 'owner': me, 'title': 'Old receipts', 'created': '2026-10-01'}),
        Note({'id': 'y', 'owner': me, 'title': 'New receipts', 'created': '2026-11-01'}),
      ],
      items: const {},
      members: const {},
      states: {
        'x': NoteState({'note': 'x', 'archived': true}),
      },
      attachments: const {},
    );
    expect([for (final n in shelfView(lib, q(Shelf.notes)).shown) n.id], ['y']);
    final v = shelfView(lib, q(Shelf.notes, query: 'receipts'));
    expect([for (final n in v.first) n.id], ['y']);
    expect([for (final n in v.second) n.id], ['x']);
    expect((v.firstLabel, v.secondLabel), ('Notes', 'Archive'));
  });

  test('Reminders: upcoming soonest first, passed latest first', () {
    final v = shelfView(library(), q(Shelf.reminders), now: DateTime.utc(2026, 11, 20));
    expect([for (final n in v.first) n.id], ['b']);
    expect([for (final n in v.second) n.id], ['c']);
    expect((v.firstLabel, v.secondLabel), ('Upcoming', 'Earlier'));
  });

  test('Trash holds the trashed', () {
    expect([for (final n in shelfView(library(), q(Shelf.trash)).shown) n.id], ['d']);
  });

  test('the memo answers again without working it out again', () {
    final memo = ShelfMemo();
    final lib = library();
    final one = memo.of(lib, q(Shelf.notes, filters: {NoteFilter.lists}));
    expect(identical(memo.of(lib, q(Shelf.notes, filters: {NoteFilter.lists})), one), isTrue);
    expect(identical(memo.of(lib, q(Shelf.notes)), one), isFalse);
    expect(identical(memo.of(library(), q(Shelf.notes)), one), isFalse);
  });
}
