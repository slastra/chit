/// chit's wire types, mirroring internal/protocol in the chit repo. The
/// server speaks these over REST and SSE; docs/design.md is the contract.
library;

import 'dart:convert';

/// Collections that clients write through ops.
abstract final class Collections {
  static const notes = 'notes';
  static const items = 'items';
  static const labels = 'labels';
  static const noteState = 'note_state';
  static const members = 'note_members';
  static const attachments = 'attachments';
}

typedef Clocks = Map<String, String>;
typedef Json = Map<String, Object?>;

Clocks _clocks(Object? v) => {
  for (final MapEntry(:key, :value) in ((v as Map?) ?? const {}).entries) '$key': '$value',
};

/// One field of one record. For note_state, [id] is the note's id.
final class Op {
  const Op({required this.collection, required this.id, required this.field, required this.value, required this.hlc});

  final String collection;
  final String id;
  final String field;
  final Object? value;
  final String hlc;

  Json toJson() => {'collection': collection, 'id': id, 'field': field, 'value': value, 'hlc': hlc};

  factory Op.fromJson(Json j) => Op(
    collection: j['collection']! as String,
    id: j['id']! as String,
    field: j['field']! as String,
    value: j['value'],
    hlc: j['hlc']! as String,
  );
}

/// The server's verdict on one op. [stale]: a newer write holds the field.
typedef OpResult = ({bool applied, bool stale, String? error});

OpResult opResultFromJson(Json j) =>
    (applied: j['applied'] == true, stale: j['stale'] == true, error: j['error'] as String?);

/// Change kinds in the feed.
enum ChangeKind {
  set,
  record,
  remove,
  revoke;

  static ChangeKind parse(String s) => values.firstWhere((k) => k.name == s, orElse: () => set);
}

final class Change {
  const Change({
    required this.seq,
    required this.kind,
    required this.collection,
    required this.record,
    this.field = '',
    this.value,
    this.hlc = '',
    this.by = '',
  });

  final int seq;
  final ChangeKind kind;
  final String collection;
  final String record;
  final String field;
  final Object? value;
  final String hlc;
  final String by;

  factory Change.fromJson(Json j) => Change(
    seq: (j['seq'] as num?)?.toInt() ?? 0,
    kind: ChangeKind.parse(j['kind'] as String? ?? 'set'),
    collection: j['collection'] as String? ?? '',
    record: j['record'] as String? ?? '',
    field: j['field'] as String? ?? '',
    value: j['value'],
    hlc: j['hlc'] as String? ?? '',
    by: j['by'] as String? ?? '',
  );
}

final class Person {
  const Person({required this.id, required this.name, required this.email});
  final String id;
  final String name;
  final String email;

  String get display => name.isNotEmpty ? name : email;

  factory Person.fromJson(Json j) =>
      Person(id: j['id'] as String? ?? '', name: j['name'] as String? ?? '', email: j['email'] as String? ?? '');
  Json toJson() => {'id': id, 'name': name, 'email': email};
}

/// Records as the replica keeps them: their wire JSON. These typed views
/// read that JSON; the replica merges the maps field by field.
final class Note {
  Note(this.json);
  final Json json;

  String get id => json['id'] as String? ?? '';
  String get owner => json['owner'] as String? ?? '';
  String get kind => json['kind'] as String? ?? 'text';
  bool get isList => kind == 'list';
  String get title => json['title'] as String? ?? '';
  String get body => json['body'] as String? ?? '';
  String get color => json['color'] as String? ?? '';
  String get trashed => json['trashed'] as String? ?? '';
  bool get deleted => json['deleted'] == true;
  String get created => json['created'] as String? ?? '';
  String get updated => json['updated'] as String? ?? '';
  Clocks get clocks => _clocks(json['clocks']);

  /// What to show: the title, else the start of the body.
  String get label {
    if (title.isNotEmpty) return title;
    final line = body.trim().split('\n').first;
    return line.isEmpty ? '' : (line.length > 60 ? '${line.substring(0, 60)}…' : line);
  }
}

final class Item {
  Item(this.json);
  final Json json;

  String get id => json['id'] as String? ?? '';
  String get note => json['note'] as String? ?? '';
  String get text => json['text'] as String? ?? '';
  bool get checked => json['checked'] == true;
  String get order => json['order'] as String? ?? '';
  int get indent => (json['indent'] as num?)?.toInt() ?? 0;
  bool get deleted => json['deleted'] == true;
  Clocks get clocks => _clocks(json['clocks']);
}

final class Member {
  Member(this.json);
  final Json json;

  String get id => json['id'] as String? ?? '';
  String get note => json['note'] as String? ?? '';
  String get user => json['user'] as String? ?? '';
  String get role => json['role'] as String? ?? 'editor';
}

/// The reader's own view of a note: what Keep keeps private on shared notes.
final class NoteState {
  NoteState(this.json);
  final Json json;

  String get note => json['note'] as String? ?? '';
  bool get pinned => json['pinned'] == true;
  bool get archived => json['archived'] == true;
  List<String> get labels => [...((json['labels'] as List?) ?? const []).cast<String>()];
  String get reminder => json['reminder'] as String? ?? '';
  bool get reminderDone => json['reminder_done'] == true;
  Clocks get clocks => _clocks(json['clocks']);
}

final class Attachment {
  Attachment(this.json);
  final Json json;

  String get id => json['id'] as String? ?? '';
  String get note => json['note'] as String? ?? '';
  String get file => json['file'] as String? ?? '';
  String get name => json['name'] as String? ?? '';
  int get size => (json['size'] as num?)?.toInt() ?? 0;
  String get type => json['type'] as String? ?? '';
  bool get isImage => type.startsWith('image/');
  bool get deleted => json['deleted'] == true;

  /// Set only on this device, for a file still waiting to upload.
  bool get pending => json['pending'] == true;
  String get local => json['local'] as String? ?? '';

  String get path => '/api/files/${Collections.attachments}/$id/$file';
}

/// Everything the caller can see, as of [seq].
final class Snapshot {
  const Snapshot({required this.seq, required this.records});
  final int seq;

  /// collection -> records, as wire JSON.
  final Map<String, List<Json>> records;

  factory Snapshot.fromJson(Json j) {
    List<Json> list(String key) => [...((j[key] as List?) ?? const []).cast<Json>()];
    return Snapshot(
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      records: {
        Collections.notes: list('notes'),
        Collections.items: list('items'),
        Collections.members: list('members'),
        Collections.noteState: list('state'),
        Collections.labels: list('labels'),
        Collections.attachments: list('attachments'),
      },
    );
  }
}

String encodeJson(Object? v) => jsonEncode(v);
Object? decodeJson(String s) => jsonDecode(s);
