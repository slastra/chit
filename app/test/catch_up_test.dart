import 'dart:convert';
import 'dart:io';

import 'package:chit/core/hlc.dart';
import 'package:chit/core/protocol.dart';
import 'package:chit/data/api.dart';
import 'package:chit/data/catch_up.dart';
import 'package:chit/data/database.dart';
import 'package:chit/data/replica.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const me = 'useruseruser001';

Json change(int seq, String note, String title) => {
  'seq': seq,
  'kind': 'record',
  'collection': 'notes',
  'record': note,
  'value': {
    'id': note,
    'owner': me,
    'kind': 'text',
    'title': title,
    'clocks': {'title': '17956512${seq.toString().padLeft(5, '0')}-0000-srv'},
  },
  'hlc': '17956512${seq.toString().padLeft(5, '0')}-0000-srv',
  'by': 'someone',
};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<Replica> fresh() async {
    final r = Replica(ChitDb(NativeDatabase.memory()));
    await r.setMeta('user', me);
    await r.setMeta('cursor', '1');
    return r;
  }

  test('catchUp reads every page and moves the cursor', () async {
    final asked = <String>[];
    final api = ChitApi(
      server: 'https://chit.example',
      client: MockClient((req) async {
        final since = req.url.queryParameters['since']!;
        asked.add(since);
        final body = since == '1'
            ? {
                'changes': [change(2, 'n1', 'One')],
                'seq': 2,
                'more': true,
              }
            : {
                'changes': [change(3, 'n2', 'Two')],
                'seq': 3,
                'more': false,
              };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    final r = await fresh();
    final seen = <int>[];
    final n = await catchUp(r, api, HlcClock('test'), onChanges: (cs, before) async => seen.add(cs.length));
    expect(n, 2);
    expect(asked, ['1', '2']);
    expect(seen, [1, 1]);
    expect(await r.cursor(), 3);
    expect((await r.read()).notes.map((n) => n.title), containsAll(['One', 'Two']));
  });

  test('the cursor never moves back', () async {
    final r = await fresh();
    await r.applyChanges(const [], 1200);
    await r.applyChanges(const [], 1100);
    expect(await r.cursor(), 1200);
  });

  test('flushOnce acks what was answered and reports refusals', () async {
    final r = await fresh();
    await r.applyLocal([
      Op(collection: Collections.notes, id: 'n9', field: 'kind', value: 'text', hlc: '1795651200000-0000-me'),
    ], me);
    final api = ChitApi(
      server: 'https://chit.example',
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'seq': 5,
            'results': [
              {'applied': false, 'stale': true},
            ],
          }),
          200,
        ),
      ),
    );
    expect(await flushOnce(r, api), isFalse);
    expect(await r.pending(), isEmpty);
  });

  test('flushAndHeal reloads the snapshot when an op is refused, undoing it here', () async {
    final r = await fresh();
    await r.applyLocal([
      Op(collection: Collections.notes, id: 'n9', field: 'kind', value: 'text', hlc: '1795651200000-0000-me'),
    ], me);
    expect((await r.read()).notes, hasLength(1));
    final asked = <String>[];
    final api = ChitApi(
      server: 'https://chit.example',
      client: MockClient((req) async {
        asked.add(req.url.path.split('/').last);
        if (req.url.path.endsWith('/ops')) {
          return http.Response(
            jsonEncode({
              'seq': 5,
              'results': [
                {'error': 'viewers cannot edit'},
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'seq': 7}), 200);
      }),
    );
    await flushAndHeal(r, api);
    expect(asked, ['ops', 'snapshot']);
    expect((await r.read()).notes, isEmpty);
    expect(await r.cursor(), 7);
  });

  test('two connections to one file wait for each other instead of failing', () async {
    final dir = await Directory.systemTemp.createTemp('chit-wal');
    final file = File('${dir.path}/chit.sqlite');
    final a = Replica(ChitDb(NativeDatabase.createInBackground(file, setup: configureConnection)));
    final b = Replica(ChitDb(NativeDatabase.createInBackground(file, setup: configureConnection)));
    await a.setMeta('user', me);
    await Future.wait([
      for (var i = 0; i < 20; i++) a.applyChanges([Change.fromJson(change(i + 10, 'a$i', 'A'))], i + 10),
      for (var i = 0; i < 20; i++) b.applyChanges([Change.fromJson(change(i + 40, 'b$i', 'B'))], i + 40),
    ]);
    expect((await a.read()).notes, hasLength(40));
    await a.db.close();
    await b.db.close();
    await dir.delete(recursive: true);
  });
}
