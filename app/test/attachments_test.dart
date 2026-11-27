import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chit/core/protocol.dart';
import 'package:chit/data/api.dart';
import 'package:chit/data/database.dart';
import 'package:chit/data/media.dart';
import 'package:chit/data/replica.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const me = 'useruseruser001';
const note = 'note00000000001';
const photo = 'file00000000001';

Snapshot snap({List<Json> attachments = const []}) => Snapshot(
  seq: 5,
  records: {
    Collections.notes: [
      {'id': note, 'owner': me, 'kind': 'text', 'title': 'Trip'},
    ],
    Collections.attachments: attachments,
  },
);

Json landed(String id) => {
  'id': id,
  'note': note,
  'file': 'photo_abc.jpg',
  'name': 'photo.jpg',
  'size': 3,
  'type': 'image/jpeg',
  'deleted': false,
  'created': '2026-11-26 10:00:00.000Z',
  'clocks': <String, String>{},
};

Future<Replica> seeded() async {
  final r = Replica(ChitDb(NativeDatabase.memory()));
  await r.setMeta('user', me);
  await r.replaceAll(snap());
  return r;
}

Future<void> queuePhoto(Replica r) => r.queueUpload(
  id: photo,
  note: note,
  name: 'photo.jpg',
  type: 'image/jpeg',
  size: 3,
  path: '/tmp/uploads/$photo/photo.jpg',
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('upload queue', () {
    test('a queued file shows at once as pending', () async {
      final r = await seeded();
      await queuePhoto(r);
      final a = (await r.read()).attachments[note]!.single;
      expect(a.pending, isTrue);
      expect(a.local, '/tmp/uploads/$photo/photo.jpg');
      expect(a.isImage, isTrue);
      expect((await r.uploads()).single.id, photo);
    });

    test('a landed file replaces the pending one and leaves the queue', () async {
      final r = await seeded();
      await queuePhoto(r);
      await r.finishUpload(landed(photo));
      final a = (await r.read()).attachments[note]!.single;
      expect(a.pending, isFalse);
      expect(a.local, isEmpty);
      expect(a.file, 'photo_abc.jpg');
      expect(await r.uploads(), isEmpty);
    });

    test('a dropped upload leaves the note', () async {
      final r = await seeded();
      await queuePhoto(r);
      await r.dropUpload(photo);
      expect((await r.read()).attachments[note], isNull);
      expect(await r.uploads(), isEmpty);
    });

    test('a resync keeps files still waiting', () async {
      final r = await seeded();
      await queuePhoto(r);
      await r.replaceAll(snap());
      expect((await r.read()).attachments[note]!.single.pending, isTrue);
      expect(await r.uploads(), hasLength(1));
    });

    test('a resync that already has the file ends its wait', () async {
      final r = await seeded();
      await queuePhoto(r);
      await r.replaceAll(snap(attachments: [landed(photo)]));
      expect((await r.read()).attachments[note]!.single.pending, isFalse);
      expect(await r.uploads(), isEmpty);
    });

    test('a database from before uploads gains the table', () async {
      // version 1 had no uploads table
      final v1 = NativeDatabase.memory(
        setup: (db) {
          db.execute(
            'CREATE TABLE records (collection TEXT NOT NULL, id TEXT NOT NULL, note TEXT NOT NULL DEFAULT \'\', '
            'data TEXT NOT NULL, PRIMARY KEY (collection, id))',
          );
          db.execute(
            'CREATE TABLE outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL, created TEXT NOT NULL)',
          );
          db.execute('CREATE TABLE meta ("key" TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)');
          db.userVersion = 1;
        },
      );
      final r = Replica(ChitDb(v1));
      await r.setMeta('user', me);
      await r.replaceAll(snap());
      await queuePhoto(r);
      expect(await r.uploads(), hasLength(1));
    });
  });

  group('kinds', () {
    test('by type, then by name', () {
      expect(MediaKind.of('image/png', 'a.png'), MediaKind.image);
      expect(MediaKind.of('video/mp4', 'a.mp4'), MediaKind.video);
      expect(MediaKind.of('audio/mpeg', 'a.mp3'), MediaKind.audio);
      expect(MediaKind.of('application/pdf', 'a.pdf'), MediaKind.pdf);
      // a sniff that came back generic falls back to the extension
      expect(MediaKind.of('application/octet-stream', 'Voice memo.m4a'), MediaKind.audio);
      expect(MediaKind.of('application/octet-stream', 'clip.MOV'), MediaKind.video);
      // AAC in MP4 sniffs as video; the name settles it
      expect(MediaKind.of('video/mp4', 'Voice memo, Nov 26 14.29.m4a'), MediaKind.audio);
      expect(MediaKind.of('video/webm', 'memo.weba'), MediaKind.audio);
      expect(MediaKind.of('video/mp4', 'clip.mp4'), MediaKind.video);
      expect(MediaKind.of('image/svg+xml', 'logo.svg'), MediaKind.other);
      expect(MediaKind.of('text/plain', 'notes.txt'), MediaKind.other);
      expect(guessType('Scan.PDF'), 'application/pdf');
      expect(formatSize(1536), '1.5 KB');
      expect(formatSize(250 << 20), '250 MB');
    });
  });

  group('api', () {
    test('upload sends the id and file as multipart, and reports progress', () async {
      http.BaseRequest? seen;
      String? body;
      final client = MockClient.streaming((req, stream) async {
        seen = req;
        body = utf8.decode(await stream.toBytes(), allowMalformed: true);
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'seq': 7, 'attachment': landed(photo)}))),
          200,
        );
      });
      final api = ChitApi(server: 'https://chit.example/', token: 'tok', device: 'desk', client: client);
      final sent = <int>[];
      final r = await api.upload(
        note,
        photo,
        'photo.jpg',
        Stream.value(Uint8List.fromList([1, 2, 3])),
        3,
        onProgress: sent.add,
      );
      expect(seen!.url.toString(), 'https://chit.example/api/chit/notes/$note/attachments');
      expect(seen!.headers['Authorization'], 'tok');
      expect(seen!.headers['X-Chit-Device'], 'desk');
      expect(body, contains('name="id"\r\n\r\n$photo'));
      expect(body, contains('name="file"; filename="photo.jpg"'));
      expect(sent.last, 3);
      expect(r.seq, 7);
      expect(r.attachment['file'], 'photo_abc.jpg');
    });

    test('a refused upload is an ApiError with the server reason', () async {
      final client = MockClient.streaming(
        (req, stream) async => http.StreamedResponse(
          Stream.value(utf8.encode('{"status":413,"message":"files can be at most 250 MB"}')),
          413,
        ),
      );
      final api = ChitApi(server: 'https://chit.example', token: 't', client: client);
      await expectLater(
        api.upload(note, photo, 'big.mov', const Stream.empty(), 0),
        throwsA(
          isA<ApiError>().having((e) => e.status, 'status', 413).having((e) => e.message, 'message', contains('250')),
        ),
      );
    });

    test('file URLs carry the token, and thumbs only when asked', () {
      final api = ChitApi(server: 'https://chit.example');
      final a = Attachment(landed(photo));
      expect(
        api.fileUrl(a, 'ft').toString(),
        'https://chit.example/api/files/attachments/$photo/photo_abc.jpg?token=ft',
      );
      expect(api.fileUrl(a, 'ft', thumb: '320x320').queryParameters['thumb'], '320x320');
    });
  });

  // A round trip against a real chit-server, when one is named (a throwaway
  // one: CHIT_TEST_SERVER=http://127.0.0.1:PORT CHIT_TEST_TOKEN=... and a
  // note the token's user owns in CHIT_TEST_NOTE).
  final server = Platform.environment['CHIT_TEST_SERVER'];
  test(
    'upload and download against a live server',
    skip: server == null ? 'set CHIT_TEST_SERVER, CHIT_TEST_TOKEN and CHIT_TEST_NOTE' : false,
    () async {
      final api = ChitApi(server: server!, token: Platform.environment['CHIT_TEST_TOKEN']!, device: 'test');
      final bytes = Uint8List.fromList(List.generate(40 << 20, (i) => i & 0xff)); // past 32 MB
      final id = 'upl${DateTime.now().millisecondsSinceEpoch}'.padRight(15, '0').substring(0, 15);
      final r = await api.upload(
        Platform.environment['CHIT_TEST_NOTE']!,
        id,
        'big.bin',
        Stream.value(bytes),
        bytes.length,
      );
      expect(r.attachment['size'], bytes.length);
      final a = Attachment(r.attachment);
      final back = await (await api.download(api.fileUrl(a, await api.fileToken())))
          .fold<int>(0, (n, c) => n + c.length);
      expect(back, bytes.length);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
