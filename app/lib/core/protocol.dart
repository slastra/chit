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

Clocks _clocks(Object? v) => {for (final MapEntry(:key, :value) in ((v as Map?) ?? const {}).entries) '$key': '$value'};

/// One field of one record. For note_state, [id] is the note's id.
final class Op {
  const Op({
    required this.collection,
    required this.id,
    required this.field,
    required this.value,
    required this.hlc,
    this.base = '',
  });

  final String collection;
  final String id;
  final String field;
  final Object? value;
  final String hlc;

  /// For free text (a title, a body, an item's text): the clock of the
  /// value this edit started from. If someone else wrote the field since,
  /// the server merges the two edits rather than keeping the later.
  final String base;

  Json toJson() => {
    'collection': collection,
    'id': id,
    'field': field,
    'value': value,
    'hlc': hlc,
    if (base.isNotEmpty) 'base': base,
  };

  factory Op.fromJson(Json j) => Op(
    collection: j['collection']! as String,
    id: j['id']! as String,
    field: j['field']! as String,
    value: j['value'],
    hlc: j['hlc']! as String,
    base: j['base'] as String? ?? '',
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
/// read that JSON; the replica merges the maps field by field. A view is
/// made fresh from a stored row and never changed, so what is costly to
/// read (parsed, split, copied) is worked out once.
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
  late final String label = () {
    if (title.isNotEmpty) return title;
    final line = body.trim().split('\n').first;
    return line.isEmpty ? '' : (line.length > 60 ? '${line.substring(0, 60)}…' : line);
  }();
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

/// One of the reader's labels (each person has their own).
final class Label {
  Label(this.json);
  final Json json;

  String get id => json['id'] as String? ?? '';
  String get name => json['name'] as String? ?? '';
  bool get deleted => json['deleted'] == true;
  Clocks get clocks => _clocks(json['clocks']);
}

/// The reader's own view of a note: what stays private to each person on a
/// shared note (pinned, archived, labels, reminder, place on the board).
final class NoteState {
  NoteState(this.json);
  final Json json;

  String get note => json['note'] as String? ?? '';
  bool get pinned => json['pinned'] == true;
  bool get archived => json['archived'] == true;
  late final List<String> labels = List.unmodifiable(((json['labels'] as List?) ?? const []).cast<String>());
  String get reminder => json['reminder'] as String? ?? '';
  bool get reminderDone => json['reminder_done'] == true;

  /// Where this person put the note on their board ("" until moved).
  String get order => json['order'] as String? ?? '';
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
  bool get deleted => json['deleted'] == true;
  String get created => json['created'] as String? ?? '';

  /// What the app does with it: show, play, page through, or offer.
  late final MediaKind kind = MediaKind.of(type, name);
  bool get isImage => kind == MediaKind.image;

  /// A file on its way, in words: waiting, or how far it has got.
  static String uploadStatus(double? progress) =>
      progress == null ? 'Waiting to upload' : 'Uploading ${(progress * 100).round()}%';

  /// Set only on this device, for a file still waiting to upload.
  bool get pending => json['pending'] == true;
  String get local => json['local'] as String? ?? '';

  String get path => '/api/files/${Collections.attachments}/$id/$file';
}

/// What a recorded voice memo's name starts with; a file named so gets the
/// microphone mark rather than a note's.
const voiceMemoName = 'Voice memo';

/// How a file is shown. By MIME type, falling back to the name's extension
/// (the server sniffs types, and a sniff can come back as octet-stream).
enum MediaKind {
  image,
  video,
  audio,
  pdf,
  other;

  static MediaKind of(String type, String name) {
    final t = type.toLowerCase();
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (t.startsWith('image/') && t != 'image/svg+xml') return image;
    // a voice memo is AAC in an MP4 container, which sniffs as video: the
    // name says it is the sound-only use of a container video shares
    if ((t == 'video/mp4' || t == 'video/webm' || t == 'application/ogg') &&
        const {'m4a', 'weba', 'oga', 'opus'}.contains(ext)) {
      return audio;
    }
    if (t.startsWith('video/')) return video;
    if (t.startsWith('audio/')) return audio;
    if (t == 'application/pdf') return pdf;
    // no type worth reading (octet-stream, say): the name's
    final guessed = guessType(name);
    return guessed == 'application/octet-stream' ? other : of(guessed, name);
  }
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

/// A MIME type from a file name, for showing a file before the server has
/// sniffed it.
String guessType(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'avif' => 'image/avif',
    'bmp' => 'image/bmp',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mkv' => 'video/x-matroska',
    '3gp' => 'video/3gpp',
    'avi' => 'video/x-msvideo',
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'weba' => 'audio/webm',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };
}
