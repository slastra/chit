import 'package:drift/drift.dart';

import '../core/protocol.dart';
import 'database.dart';

/// The local copy of everything the user can see, plus the outbox of edits
/// the server has not accepted yet. A port of chitd's internal/replica:
/// records merge field by field, newer clock wins, the same rule as the
/// server, so the two cannot disagree.
final class Replica {
  Replica(this.db, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final ChitDb db;
  final DateTime Function() _now;

  // ---- meta --------------------------------------------------------------

  Future<String?> meta(String key) async =>
      (await (db.select(db.meta)..where((m) => m.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setMeta(String key, String value) =>
      db.into(db.meta).insertOnConflictUpdate(MetaCompanion.insert(key: key, value: value));

  Future<int> cursor() async => int.tryParse(await meta('cursor') ?? '') ?? 0;

  /// Forgets every record, the outbox and the cursor (another account or
  /// server). The device id stays.
  Future<void> wipe() => db.transaction(() async {
    await db.delete(db.records).go();
    await db.delete(db.outbox).go();
    await db.delete(db.uploads).go();
    await (db.delete(db.meta)..where((m) => m.key.isIn(['cursor', 'user', 'server']))).go();
  });

  // ---- records -------------------------------------------------------------

  static String _keyOf(String collection, Json rec) =>
      collection == Collections.noteState ? rec['note'] as String? ?? '' : rec['id'] as String? ?? '';

  static String _noteOf(String collection, Json rec) =>
      collection == Collections.notes ? rec['id'] as String? ?? '' : rec['note'] as String? ?? '';

  Future<Json?> _load(String collection, String id) async {
    final row = await (db.select(
      db.records,
    )..where((r) => r.collection.equals(collection) & r.id.equals(id))).getSingleOrNull();
    return row == null ? null : (decodeJson(row.data)! as Map).cast<String, Object?>();
  }

  Future<void> _store(String collection, Json rec) => db
      .into(db.records)
      .insertOnConflictUpdate(
        RecordsCompanion.insert(
          collection: collection,
          id: _keyOf(collection, rec),
          note: Value(_noteOf(collection, rec)),
          data: encodeJson(rec),
        ),
      );

  /// PocketBase's datetime format, so local and server stamps sort together.
  String _stamp() => _now()
      .toUtc()
      .toIso8601String()
      .replaceFirst('T', ' ')
      .replaceFirstMapped(RegExp(r'(\.\d{3})\d*Z$'), (m) => '${m[1]}Z');

  /// Bumps a note's `updated`, so recently edited notes sort first even for
  /// edits the feed reports field by field.
  Future<void> _touch(String noteId) async {
    if (noteId.isEmpty) return;
    final n = await _load(Collections.notes, noteId);
    if (n == null) return;
    n['updated'] = _stamp();
    await _store(Collections.notes, n);
  }

  /// Replaces the replica with a server snapshot. Queued local edits are
  /// re-applied on top, and files still waiting to upload put back, so
  /// offline work survives a resync. A queued file the snapshot already
  /// holds did land (its answer was lost): it leaves the queue.
  Future<void> replaceAll(Snapshot s) => db.transaction(() async {
    await db.delete(db.records).go();
    final landed = <String>{};
    for (final MapEntry(key: collection, value: list) in s.records.entries) {
      for (final rec in list) {
        await _store(collection, rec);
        if (collection == Collections.attachments) landed.add(rec['id'] as String? ?? '');
      }
    }
    final me = await meta('user') ?? '';
    for (final q in await pending()) {
      await _applyOp(q.op, me);
    }
    for (final u in await uploads()) {
      if (landed.contains(u.id)) {
        await (db.delete(db.uploads)..where((r) => r.id.equals(u.id))).go();
      } else {
        await _store(Collections.attachments, _pendingRecord(u));
      }
    }
    await setMeta('cursor', '${s.seq}');
  });

  /// Merges feed changes and moves the cursor, atomically. The cursor only
  /// moves forward: the live stream and a background catch-up may both
  /// apply the same stretch, in either order.
  Future<void> applyChanges(List<Change> changes, int cursor) => db.transaction(() async {
    for (final c in changes) {
      await _applyChange(c);
    }
    if (cursor > await this.cursor()) await setMeta('cursor', '$cursor');
  });

  Future<void> _applyChange(Change c) async {
    switch (c.kind) {
      case ChangeKind.revoke:
        await (db.delete(db.records)..where((r) => r.note.equals(c.record))).go();
      case ChangeKind.remove:
        await (db.delete(db.records)..where((r) => r.collection.equals(c.collection) & r.id.equals(c.record))).go();
      case ChangeKind.record:
        final incoming = (c.value! as Map).cast<String, Object?>();
        final merged = mergeRecord(await _load(c.collection, _keyOf(c.collection, incoming)), incoming);
        await _store(c.collection, merged);
        if (c.collection != Collections.notes) await _touch(_noteOf(c.collection, merged));
      case ChangeKind.set:
        // A set for a record never seen: the record (or a resync) brings it.
        final cur = await _load(c.collection, c.record);
        if (cur != null && setField(cur, c.field, c.value, c.hlc)) {
          await _store(c.collection, cur);
          await _touch(_noteOf(c.collection, cur));
        }
    }
  }

  /// Applies this device's ops and queues them for the server. An op already
  /// stale here is reported and not queued: the server would refuse it too.
  Future<List<OpResult>> applyLocal(List<Op> ops, String me) => db.transaction(() async {
    final results = <OpResult>[];
    for (final op in ops) {
      final r = await _applyOp(op, me);
      results.add(r);
      if (r.applied) {
        await db.into(db.outbox).insert(OutboxCompanion.insert(op: encodeJson(op.toJson()), created: _stamp()));
      }
    }
    return results;
  });

  Future<OpResult> _applyOp(Op op, String me) async {
    var cur = await _load(op.collection, op.id);
    if (cur == null) {
      final fresh = blankRecord(op, me, _stamp());
      if (fresh == null) return (applied: false, stale: false, error: 'cannot create ${op.collection} here');
      cur = fresh;
    }
    if (!setField(cur, op.field, op.value, op.hlc)) return (applied: false, stale: true, error: null);
    await _store(op.collection, cur);
    await _touch(_noteOf(op.collection, cur));
    return (applied: true, stale: false, error: null);
  }

  // ---- outbox --------------------------------------------------------------

  Future<List<({int seq, Op op})>> pending({int limit = 0}) async {
    final q = db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.seq)]);
    if (limit > 0) q.limit(limit);
    return [
      for (final row in await q.get())
        (seq: row.seq, op: Op.fromJson((decodeJson(row.op)! as Map).cast<String, Object?>())),
    ];
  }

  /// What another isolate's writes would move: the feed cursor (a
  /// catch-up) and the outbox (an edit made from a notification). Two
  /// marks that differ mean the database changed underneath.
  Future<String> writeMark() async {
    final count = db.outbox.seq.count(), last = db.outbox.seq.max();
    final row = await (db.selectOnly(db.outbox)..addColumns([count, last])).getSingle();
    return '${await cursor()}/${row.read(count)}/${row.read(last)}';
  }

  Stream<int> watchPendingCount() {
    final count = db.outbox.seq.count();
    return (db.selectOnly(db.outbox)..addColumns([count])).map((r) => r.read(count) ?? 0).watchSingle();
  }

  Future<void> ack(Iterable<int> seqs) => (db.delete(db.outbox)..where((o) => o.seq.isIn(seqs))).go();

  // ---- uploads -------------------------------------------------------------

  /// How a queued file shows until it lands: an attachment marked pending,
  /// pointing at the local copy.
  static Json _pendingRecord(Upload u) => {
    'id': u.id,
    'note': u.note,
    'file': '',
    'name': u.name,
    'size': u.size,
    'type': u.type,
    'deleted': false,
    'created': u.created,
    'pending': true,
    'local': u.path ?? '',
    'clocks': <String, String>{},
  };

  /// Queues a file for [note]: it shows at once as a pending attachment and
  /// waits in the upload queue.
  Future<void> queueUpload({
    required String id,
    required String note,
    required String name,
    required String type,
    required int size,
    String? path,
    Uint8List? bytes,
  }) => db.transaction(() async {
    final row = UploadsCompanion.insert(
      id: id,
      note: note,
      name: name,
      type: type,
      size: size,
      path: Value(path),
      bytes: Value(bytes),
      created: _stamp(),
    );
    await db.into(db.uploads).insert(row);
    final u = await (db.select(db.uploads)..where((r) => r.id.equals(id))).getSingle();
    await _store(Collections.attachments, _pendingRecord(u));
    await _touch(note);
  });

  /// Files waiting to upload, oldest first.
  Future<List<Upload>> uploads() => (db.select(db.uploads)..orderBy([(u) => OrderingTerm.asc(u.created)])).get();

  Future<Upload?> upload(String id) => (db.select(db.uploads)..where((u) => u.id.equals(id))).getSingleOrNull();

  /// A file landed: the server's record replaces the pending one outright
  /// (a merge would keep the local-only pending and local fields).
  Future<void> finishUpload(Json attachment) => db.transaction(() async {
    final id = attachment['id'] as String? ?? '';
    await (db.delete(db.uploads)..where((u) => u.id.equals(id))).go();
    final cur = await _load(Collections.attachments, id);
    // the feed may have brought it first, with a newer deleted flag
    final merged = mergeRecord(
      cur == null
          ? null
          : ({...cur}
              ..remove('pending')
              ..remove('local')),
      attachment,
    );
    await _store(Collections.attachments, merged);
  });

  /// Gives up on a queued file: it leaves the queue and the note.
  Future<void> dropUpload(String id) => db.transaction(() async {
    await (db.delete(db.uploads)..where((u) => u.id.equals(id))).go();
    await (db.delete(db.records)..where((r) => r.collection.equals(Collections.attachments) & r.id.equals(id))).go();
  });

  // ---- reading -------------------------------------------------------------

  /// Every record, live: a new [Library] after each change. Records whose
  /// stored JSON did not change come through as the same objects (decoded
  /// once), so whatever compares them can tell what changed by identity.
  Stream<Library> watch() {
    final seen = RecordCache();
    return db.select(db.records).watch().map((rows) => Library.fromRows(rows, seen));
  }

  Future<Library> read() async => Library.fromRows(await db.select(db.records).get());

  /// Every clock on every record, deleted ones too: what a fresh clock must
  /// not fall behind.
  Future<Iterable<String>> clocks() async => [
    for (final r in await db.select(db.records).get())
      ...((((decodeJson(r.data) as Map?)?['clocks'] as Map?) ?? const {}).values.whereType<String>()),
  ];
}

/// Folds a whole incoming record into the local one. Fields with clocks keep
/// whichever write is newer; fields without (id, owner, file, created) come
/// from the server.
Json mergeRecord(Json? cur, Json incoming) {
  if (cur == null) return {...incoming};
  final curClocks = <String, String>{...?(cur['clocks'] as Map?)?.cast<String, String>()};
  final inClocks = <String, String>{...?(incoming['clocks'] as Map?)?.cast<String, String>()};
  for (final MapEntry(:key, :value) in incoming.entries) {
    if (key == 'clocks') continue;
    final h = inClocks[key];
    if (h != null) {
      if (h.compareTo(curClocks[key] ?? '') > 0) {
        cur[key] = value;
        curClocks[key] = h;
      }
    } else if (!curClocks.containsKey(key)) {
      cur[key] = value;
    }
  }
  cur['clocks'] = curClocks;
  return cur;
}

/// Applies one write if its clock is newer than the field's.
bool setField(Json rec, String field, Object? value, String hlc) {
  final clocks = <String, String>{...?(rec['clocks'] as Map?)?.cast<String, String>()};
  if (hlc.compareTo(clocks[field] ?? '') <= 0) return false;
  rec[field] = value;
  clocks[field] = hlc;
  rec['clocks'] = clocks;
  return true;
}

/// The starting point for a record created on this device.
Json? blankRecord(Op op, String me, String now) => switch (op.collection) {
  Collections.notes => {'id': op.id, 'owner': me, 'kind': 'text', 'created': now, 'updated': now},
  Collections.items => {'id': op.id},
  Collections.labels => {'id': op.id},
  Collections.noteState => {'note': op.id, 'labels': <String>[]},
  _ => null,
};

/// A view of the replica: typed records, grouped for the UI. Deleted records
/// and everything under a deleted note are left out.
final class Library {
  Library({
    required this.notes,
    required this.items,
    required this.members,
    required this.states,
    required this.attachments,
    this.labels = const [],
  });

  final List<Note> notes;
  final Map<String, List<Item>> items; // by note, in order
  final Map<String, List<Member>> members; // by note
  final Map<String, NoteState> states; // by note
  final Map<String, List<Attachment>> attachments; // by note
  final List<Label> labels; // live ones, by name

  /// The notes by id.
  late final Map<String, Note> notesById = {for (final n in notes) n.id: n};

  /// Every live attachment by id.
  late final Map<String, Attachment> attachmentsById = {
    for (final list in attachments.values)
      for (final a in list) a.id: a,
  };

  Note? note(String id) => notesById[id];

  static final empty = Library(
    notes: const [],
    items: const {},
    members: const {},
    states: const {},
    attachments: const {},
  );

  /// The Library of [rows]. With [seen] (kept from one read to the next),
  /// a row whose JSON is unchanged gives back its record from last time.
  factory Library.fromRows(List<StoredRecord> rows, [RecordCache? seen]) {
    final cache = seen ?? RecordCache();
    final kept = <String, (String, Object)>{};
    T typed<T extends Object>(StoredRecord r, T Function(Json) make) {
      final key = '${r.collection}/${r.id}';
      final hit = cache._records[key];
      final T record;
      if (hit != null && hit.$1 == r.data && hit.$2 is T) {
        record = hit.$2 as T;
      } else {
        record = make((decodeJson(r.data)! as Map).cast<String, Object?>());
      }
      kept[key] = (r.data, record);
      return record;
    }

    final notes = [
      for (final r in rows)
        if (r.collection == Collections.notes) typed(r, Note.new),
    ].where((n) => !n.deleted).toList();
    final live = {for (final n in notes) n.id};
    final items = <String, List<Item>>{};
    final members = <String, List<Member>>{};
    final states = <String, NoteState>{};
    final attachments = <String, List<Attachment>>{};
    final labels = <Label>[];
    for (final r in rows) {
      switch (r.collection) {
        case Collections.labels:
          final l = typed(r, Label.new);
          if (!l.deleted && l.name.trim().isNotEmpty) labels.add(l);
        case Collections.items:
          final it = typed(r, Item.new);
          if (!it.deleted && live.contains(it.note)) (items[it.note] ??= []).add(it);
        case Collections.members:
          final m = typed(r, Member.new);
          if (live.contains(m.note)) (members[m.note] ??= []).add(m);
        case Collections.noteState:
          final st = typed(r, NoteState.new);
          if (live.contains(st.note)) states[st.note] = st;
        case Collections.attachments:
          final a = typed(r, Attachment.new);
          if (!a.deleted && live.contains(a.note)) (attachments[a.note] ??= []).add(a);
      }
    }
    for (final list in items.values) {
      list.sort((a, b) => a.order.compareTo(b.order));
    }
    for (final list in attachments.values) {
      list.sort((a, b) => a.created.compareTo(b.created));
    }
    labels.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    cache._records = kept;
    return Library(
      notes: notes,
      items: items,
      members: members,
      states: states,
      attachments: attachments,
      labels: labels,
    );
  }

  /// The reader's state for [note]; an empty one (not pinned, no labels)
  /// for a note they have never touched.
  NoteState stateOf(String note) => states[note] ?? (_blank[note] ??= NoteState({'note': note}));
  final _blank = <String, NoteState>{};

  /// Everything one note's card shows, for comparing with the last one.
  NoteView viewOf(String note) => NoteView(
    note: notesById[note]!,
    state: states[note],
    items: items[note] ?? const [],
    attachments: attachments[note] ?? const [],
    members: members[note] ?? const [],
    labels: labelsOf(note),
  );

  /// The note's labels for the reader, by name; ids of deleted or unknown
  /// labels are left out.
  List<Label> labelsOf(String note) {
    final ids = stateOf(note).labels.toSet();
    return [
      for (final l in labels)
        if (ids.contains(l.id)) l,
    ];
  }
}

/// A list that equals another holding the same record objects: for
/// watching one part of the Library (with `select`) without hearing about
/// every other change.
final class Same<T> {
  const Same(this.list);
  final List<T> list;

  @override
  bool operator ==(Object other) => other is Same<T> && NoteView._same(other.list, list);

  @override
  int get hashCode => list.length;
}

/// The records one read of the replica decoded, kept for the next, which
/// reuses those whose stored JSON is unchanged.
final class RecordCache {
  Map<String, (String, Object)> _records = const {};
}

/// One note and what goes with it, as its card shows them. Two views are
/// equal when they hold the same record objects, which (with a
/// [RecordCache]) means nothing about the note changed.
final class NoteView {
  const NoteView({
    required this.note,
    required this.state,
    required this.items,
    required this.attachments,
    required this.members,
    required this.labels,
  });
  final Note note;
  final NoteState? state;
  final List<Item> items;
  final List<Attachment> attachments;
  final List<Member> members;
  final List<Label> labels;

  static bool _same<T>(List<T> a, List<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is NoteView &&
      identical(other.note, note) &&
      identical(other.state, state) &&
      _same(other.items, items) &&
      _same(other.attachments, attachments) &&
      _same(other.members, members) &&
      _same(other.labels, labels);

  @override
  int get hashCode => note.hashCode;
}
