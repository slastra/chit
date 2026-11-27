import 'dart:async';
import 'dart:convert';

import 'package:chit/core/hlc.dart';
import 'package:chit/core/protocol.dart';
import 'package:chit/data/api.dart';
import 'package:chit/data/database.dart';
import 'package:chit/data/replica.dart';
import 'package:chit/data/sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const me = 'useruseruser001';

String hlc(int n) => '17956512${n.toString().padLeft(5, '0')}-0000-srv';

/// [n] changes from another device, as one read from the socket.
String burst(int n) => [
  for (var i = 1; i <= n; i++)
    'id: ${i + 1}\nevent: change\ndata: ${jsonEncode({
      'seq': i + 1,
      'kind': 'record',
      'collection': 'notes',
      'record': 'note$i',
      'value': {
        'id': 'note$i',
        'owner': me,
        'kind': 'text',
        'title': 'Note $i',
        'clocks': {'title': hlc(i)},
      },
      'hlc': hlc(i),
      'by': 'someone',
    })}\n\n',
].join();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<Replica> fresh() async {
    final r = Replica(ChitDb(NativeDatabase.memory()));
    await r.setMeta('user', me);
    await r.setMeta('cursor', '1');
    return r;
  }

  test('a burst of remote changes lands as one Library, not one per change', () async {
    final replica = await fresh();
    final body = StreamController<List<int>>();
    final api = ChitApi(
      server: 'https://chit.example',
      token: 'x',
      client: MockClient.streaming((req, _) async {
        if (req.url.path.endsWith('/stream')) return http.StreamedResponse(body.stream, 200);
        // the outbox flush: nothing queued, nothing to say
        return http.StreamedResponse(Stream.value(utf8.encode('{"results":[]}')), 200);
      }),
    );
    final engine = SyncEngine(replica: replica, api: api, me: me, clock: HlcClock('dev00001'));
    final seen = <int>[];
    final sub = replica.watch().listen((lib) => seen.add(lib.notes.length));
    await engine.start();
    // the first Library, before anything arrived
    await pumpEventQueue();
    final before = seen.length;

    body.add(utf8.encode(burst(50)));
    await pumpEventQueue(times: 200);

    expect((await replica.read()).notes, hasLength(50));
    expect(await replica.cursor(), 51);
    expect(seen.last, 50);
    // one transaction for the burst (drift may report it once or twice)
    expect(seen.length - before, lessThanOrEqualTo(2));

    await body.close();
    await sub.cancel();
    await engine.stop();
  });

  test('stop() after a nudge does not throw', () async {
    final replica = await fresh();
    final api = ChitApi(server: 'https://chit.example', client: MockClient((_) async => http.Response('', 503)));
    final engine = SyncEngine(replica: replica, api: api, me: me, clock: HlcClock('dev00001'));
    await engine.start();
    // the stream fails, and the engine sleeps on its backoff
    await pumpEventQueue(times: 50);
    engine.nudge();
    await pumpEventQueue(times: 50);
    await expectLater(engine.stop(), completes);
  });

  test('the clock starts past every record it has seen, items too', () async {
    final replica = await fresh();
    final late = '${DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch}-0000-srv';
    await replica.applyChanges([
      Change.fromJson({
        'seq': 2,
        'kind': 'record',
        'collection': 'notes',
        'record': 'n1',
        'value': {'id': 'n1', 'owner': me, 'kind': 'list', 'clocks': <String, String>{}},
        'hlc': hlc(1),
        'by': me,
      }),
      Change.fromJson({
        'seq': 3,
        'kind': 'record',
        'collection': 'items',
        'record': 'i1',
        'value': {
          'id': 'i1',
          'note': 'n1',
          'text': 'milk',
          'clocks': {'text': late},
        },
        'hlc': late,
        'by': 'someone',
      }),
    ], 3);
    final clock = HlcClock('dev00001');
    final api = ChitApi(server: 'https://chit.example', client: MockClient((_) async => http.Response('', 503)));
    final engine = SyncEngine(replica: replica, api: api, me: me, clock: clock);
    await engine.start();
    expect(clock.now().compareTo(late), greaterThan(0));
    await engine.stop();
  });

  test('a refused op resyncs by ending the stream, then streaming from the snapshot', () async {
    final replica = await fresh();
    final asked = <String>[];
    final streams = <StreamController<List<int>>>[];
    final api = ChitApi(
      server: 'https://chit.example',
      token: 'x',
      client: MockClient.streaming((req, _) async {
        final path = req.url.path;
        if (path.endsWith('/stream')) {
          asked.add('stream ${req.url.queryParameters['since']}');
          final body = StreamController<List<int>>();
          streams.add(body);
          return http.StreamedResponse(body.stream, 200);
        }
        if (path.endsWith('/ops')) {
          asked.add('ops');
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'seq': 9,
                  'results': [
                    {'error': 'viewers cannot edit'},
                  ],
                }),
              ),
            ),
            200,
          );
        }
        if (path.endsWith('/snapshot')) {
          asked.add('snapshot');
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'seq': 40}))), 200);
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
      }),
    );
    final engine = SyncEngine(replica: replica, api: api, me: me, clock: HlcClock('dev00001'));
    await engine.start();
    await pumpEventQueue(times: 50);
    expect(asked, ['stream 1']);

    await engine.edit([engine.op(Collections.notes, 'n1', 'title', 'Mine')]);
    await pumpEventQueue(times: 200);

    // the first stream ended before the snapshot, and the next began at its seq
    expect(asked, ['stream 1', 'ops', 'snapshot', 'stream 40']);
    expect(await replica.cursor(), 40);

    for (final b in streams) {
      await b.close();
    }
    await engine.stop();
  });
}
