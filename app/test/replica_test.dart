import 'package:chit/core/hlc.dart';
import 'package:chit/core/protocol.dart';
import 'package:chit/data/database.dart';
import 'package:chit/data/replica.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

// Ports of chitd's internal/replica tests: the two must merge identically.
const me = 'useruseruser001';
const list = 'note00000000001';
const milk = 'item00000000001';

Op op(String collection, String id, String field, Object? value, String hlc) =>
    Op(collection: collection, id: id, field: field, value: value, hlc: hlc);

Future<Replica> seeded() async {
  final r = Replica(ChitDb(NativeDatabase.memory()));
  await r.setMeta('user', me);
  await r.replaceAll(
    Snapshot(
      seq: 10,
      records: {
        Collections.notes: [
          {
            'id': list,
            'owner': me,
            'kind': 'list',
            'title': 'Groceries',
            'clocks': {'title': '1795651200000-0000-srv'},
          },
        ],
        Collections.items: [
          {
            'id': milk,
            'note': list,
            'text': 'milk',
            'order': '1',
            'clocks': {'text': '1795651200000-0000-srv'},
          },
        ],
      },
    ),
  );
  return r;
}

HlcClock clock() => HlcClock('desk')..observe('1795651200000-0000-srv');

void main() {
  // each test opens its own in-memory database on purpose
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('local edits apply, queue, and read back', () async {
    final r = await seeded();
    final c = clock();
    final res = await r.applyLocal([
      op(Collections.items, milk, 'checked', true, c.now()),
      op(Collections.items, 'item00000000002', 'note', list, c.now()),
      op(Collections.items, 'item00000000002', 'text', 'eggs', c.now()),
      op(Collections.items, 'item00000000002', 'order', '2', c.now()),
    ], me);
    expect(res.every((x) => x.applied), isTrue);
    expect((await r.pending()).length, 4);
    final lib = await r.read();
    expect(lib.items[list]!.map((i) => (i.text, i.checked)), [('milk', true), ('eggs', false)]);
  });

  test('feed merges per field', () async {
    final r = await seeded();
    await r.applyChanges([
      const Change(
        seq: 11,
        kind: ChangeKind.set,
        collection: Collections.items,
        record: milk,
        field: 'text',
        value: 'oat milk',
        hlc: '1795651300000-0000-pix',
      ),
      const Change(
        seq: 12,
        kind: ChangeKind.set,
        collection: Collections.notes,
        record: list,
        field: 'title',
        value: 'stale',
        hlc: '1795651100000-0000-pix',
      ),
    ], 12);
    final lib = await r.read();
    expect(lib.items[list]!.single.text, 'oat milk');
    expect(lib.notes.single.title, 'Groceries');
    expect(await r.cursor(), 12);
  });

  test('a whole record keeps the newer local field', () async {
    final r = await seeded();
    await r.applyLocal([op(Collections.notes, list, 'title', 'Weekly groceries', '1795651400000-0000-desk')], me);
    await r.applyChanges([
      Change(
        seq: 11,
        kind: ChangeKind.record,
        collection: Collections.notes,
        record: list,
        value: {
          'id': list,
          'owner': me,
          'kind': 'list',
          'title': 'Groceries',
          'color': 'green',
          'clocks': {'title': '1795651200000-0000-srv', 'color': '1795651500000-0000-srv'},
        },
      ),
    ], 11);
    final n = (await r.read()).notes.single;
    expect((n.title, n.color), ('Weekly groceries', 'green'));
  });

  test('revoke drops the note and everything under it', () async {
    final r = await seeded();
    await r.applyChanges([
      Change(
        seq: 11,
        kind: ChangeKind.record,
        collection: Collections.noteState,
        record: list,
        value: {
          'note': list,
          'pinned': true,
          'labels': <String>[],
          'clocks': {'pinned': '1795651200000-0000-srv'},
        },
      ),
      const Change(seq: 12, kind: ChangeKind.revoke, collection: Collections.notes, record: list),
    ], 12);
    final lib = await r.read();
    expect(lib.notes, isEmpty);
    expect(lib.items, isEmpty);
    expect(lib.states, isEmpty);
  });

  test('a resync keeps offline edits', () async {
    final r = await seeded();
    final c = clock();
    await r.applyLocal([
      op(Collections.notes, 'note00000000009', 'kind', 'text', c.now()),
      op(Collections.notes, 'note00000000009', 'title', 'Written offline', c.now()),
      op(Collections.items, milk, 'checked', true, c.now()),
    ], me);
    await r.replaceAll(
      Snapshot(
        seq: 10,
        records: {
          Collections.notes: [
            {'id': list, 'owner': me, 'kind': 'list', 'title': 'Groceries'},
          ],
          Collections.items: [
            {'id': milk, 'note': list, 'text': 'milk', 'order': '1'},
          ],
        },
      ),
    );
    final lib = await r.read();
    expect(lib.notes.where((n) => n.title == 'Written offline' && n.owner == me), hasLength(1));
    expect(lib.items[list]!.single.checked, isTrue);
    expect((await r.pending()).length, 3);
  });

  test('a locally stale op is not queued', () async {
    final r = await seeded();
    final res = await r.applyLocal([op(Collections.notes, list, 'title', 'old', '1795651100000-0000-desk')], me);
    expect(res.single.stale, isTrue);
    expect(await r.pending(), isEmpty);
  });

  test('ack empties the outbox', () async {
    final r = await seeded();
    await r.applyLocal([op(Collections.items, milk, 'checked', true, clock().now())], me);
    final q = await r.pending();
    await r.ack(q.map((x) => x.seq));
    expect(await r.pending(), isEmpty);
  });

  test('watch emits after every change', () async {
    final r = await seeded();
    final titles = r.watch().map((l) => l.notes.single.title).take(2).toList();
    await Future<void>.delayed(Duration.zero);
    await r.applyLocal([op(Collections.notes, list, 'title', 'Shop', clock().now())], me);
    expect(await titles, ['Groceries', 'Shop']);
  });
}
