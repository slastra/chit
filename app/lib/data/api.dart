import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/protocol.dart';
import 'http_client.dart';

/// The server said the session is gone (expired or revoked).
final class Unauthorized implements Exception {
  const Unauthorized();
  @override
  String toString() => 'not signed in, or the session expired';
}

/// An error answer from the server.
final class ApiError implements Exception {
  const ApiError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// One event on the change stream.
sealed class StreamEvent {
  const StreamEvent(this.seq);
  final int seq;
}

final class ChangeEvent extends StreamEvent {
  const ChangeEvent(super.seq, this.change);
  final Change change;
}

/// The server accepted the stream: the connection is live.
final class OpenEvent extends StreamEvent {
  const OpenEvent() : super(0);
}

/// The cursor moved past rows this reader cannot see; nothing to apply.
final class CursorEvent extends StreamEvent {
  const CursorEvent(super.seq);
}

/// chit-server's REST and SSE routes (docs/design.md). PocketBase handles
/// accounts; everything note-shaped goes through /api/chit.
final class ChitApi {
  ChitApi({required String server, this.token = '', this.device = '', http.Client? client})
    : server = server.replaceAll(RegExp(r'/+$'), ''),
      _http = client ?? makeHttpClient();

  final String server;
  String token;
  final String device;
  final http.Client _http;

  Map<String, String> get _headers => {
    if (token.isNotEmpty) 'Authorization': token,
    if (device.isNotEmpty) 'X-Chit-Device': device,
  };

  /// [asDevice] false sends no device id, so the change comes back on this
  /// device's own feed (the server leaves a device's own edits out, which
  /// suits edits already applied here, not a share made on the server).
  Future<Object?> _send(String method, String path, {Object? body, bool asDevice = true}) async {
    final req = http.Request(method, Uri.parse('$server$path'))..headers.addAll(_headers);
    if (!asDevice) req.headers.remove('X-Chit-Device');
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final resp = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 30)));
    return _decode(resp.statusCode, resp.body);
  }

  static Object? _decode(int status, String body) {
    if (status == 401) throw const Unauthorized();
    Object? json;
    try {
      json = body.isEmpty ? null : jsonDecode(body);
    } on FormatException {
      json = null;
    }
    if (status >= 300) {
      final message = json is Map ? json['message'] as String? : null;
      throw ApiError(status, message ?? 'the server answered $status');
    }
    return json;
  }

  /// Signs in; returns the token and the account.
  Future<({String token, Person user})> login(String email, String password) async {
    try {
      final j = await _send(
        'POST',
        '/api/collections/users/auth-with-password',
        body: {'identity': email, 'password': password},
      ) as Json;
      return (token: j['token']! as String, user: Person.fromJson((j['record']! as Map).cast()));
    } on ApiError catch (e) {
      if (e.status == 400) throw const ApiError(400, 'Wrong email or password.');
      rethrow;
    }
  }

  /// Trades the token for a fresh one.
  Future<({String token, Person user})> refresh() async {
    final j = await _send('POST', '/api/collections/users/auth-refresh') as Json;
    return (token: j['token']! as String, user: Person.fromJson((j['record']! as Map).cast()));
  }

  /// When the token expires, read from its claims (unverified; the server
  /// checks the signature).
  static DateTime? tokenExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      final exp = (claims['exp'] as num?)?.toInt();
      return exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } on FormatException {
      return null;
    }
  }

  Future<List<Person>> people() async {
    final j = await _send('GET', '/api/collections/users/records?perPage=500&sort=name&fields=id,name,email') as Json;
    return [for (final p in (j['items'] as List? ?? const [])) Person.fromJson((p as Map).cast())];
  }

  /// Uploads one file to [note] as attachment [id] (client-made, so a retry
  /// after a lost answer is harmless). The server reads the name, size and
  /// type itself. [onProgress] hears the bytes handed to the connection.
  Future<({int seq, Json attachment})> upload(
    String note,
    String id,
    String name,
    Stream<List<int>> bytes,
    int length, {
    void Function(int sent)? onProgress,
  }) async {
    var sent = 0;
    final counted = bytes.map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent);
      return chunk;
    });
    final req = http.MultipartRequest('POST', Uri.parse('$server/api/chit/notes/$note/attachments'))
      ..headers.addAll(_headers)
      ..fields['id'] = id
      ..files.add(http.MultipartFile('file', counted, length, filename: name));
    // a 250 MB file on a slow uplink takes a while
    final resp = await http.Response.fromStream(await _http.send(req).timeout(const Duration(minutes: 30)));
    final j = _decode(resp.statusCode, resp.body)! as Json;
    return (seq: (j['seq'] as num?)?.toInt() ?? 0, attachment: (j['attachment']! as Map).cast<String, Object?>());
  }

  /// A short-lived token for downloading protected files.
  Future<String> fileToken() async => ((await _send('POST', '/api/files/token'))! as Json)['token']! as String;

  /// Where to download [a] (or one of its thumbnails, images only:
  /// "320x320" or "1080x0") with a file token. The request needs no other
  /// credentials.
  Uri fileUrl(Attachment a, String fileToken, {String? thumb}) =>
      Uri.parse('$server${a.path}').replace(queryParameters: {'token': fileToken, 'thumb': ?thumb});

  /// The body of a GET as it arrives.
  Future<Stream<List<int>>> download(Uri url) async {
    final resp = await _http.send(http.Request('GET', url)).timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 300) {
      final body = await resp.stream.bytesToString();
      _decode(resp.statusCode, body);
    }
    return resp.stream;
  }

  /// Changes since [since], a page at a time: [more] when the page was
  /// full (ask again from [seq]).
  Future<({List<Change> changes, int seq, bool more})> changes(int since) async {
    final j = (await _send('GET', '/api/chit/changes?since=$since'))! as Json;
    return (
      changes: [for (final c in (j['changes'] as List? ?? const [])) Change.fromJson((c as Map).cast())],
      seq: (j['seq'] as num?)?.toInt() ?? since,
      more: j['more'] == true,
    );
  }

  Future<Snapshot> snapshot() async => Snapshot.fromJson((await _send('GET', '/api/chit/snapshot'))! as Json);

  Future<({int seq, List<OpResult> results})> ops(List<Op> ops) async {
    final j = await _send(
      'POST',
      '/api/chit/ops',
      body: {
        'device': device,
        'ops': [for (final o in ops) o.toJson()],
      },
    ) as Json;
    return (
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      results: [for (final r in (j['results'] as List? ?? const [])) opResultFromJson((r as Map).cast())],
    );
  }

  Future<int> share(String note, String user, {String role = 'editor'}) async =>
      ((await _send('POST', '/api/chit/notes/$note/members', body: {'user': user, 'role': role}, asDevice: false)
                  as Json)['seq']
              as num?)
          ?.toInt() ??
      0;

  Future<void> unshare(String note, String user) =>
      _send('DELETE', '/api/chit/notes/$note/members/$user', asDevice: false);

  /// Follows the change stream from [since] until the connection ends (the
  /// caller reconnects) or the subscription is cancelled, which closes the
  /// connection. One that stays silent for two missed pings counts as dead.
  Stream<StreamEvent> stream(int since) async* {
    final req = http.Request('GET', Uri.parse('$server/api/chit/stream?since=$since'))
      ..headers.addAll(_headers)
      ..headers['Accept'] = 'text/event-stream';
    if (since > 0) req.headers['Last-Event-ID'] = '$since';
    final resp = await _http.send(req);
    if (resp.statusCode == 401) throw const Unauthorized();
    if (resp.statusCode != 200) throw ApiError(resp.statusCode, 'stream: ${resp.reasonPhrase}');
    yield const OpenEvent();

    const silence = Duration(minutes: 2, seconds: 10);
    final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(silence);
    var id = '', event = '';
    final data = StringBuffer();
    await for (final line in lines) {
      if (line.isEmpty) {
        final seq = int.tryParse(id);
        if (event == 'change' && data.isNotEmpty) {
          final change = Change.fromJson((jsonDecode(data.toString()) as Map).cast());
          yield ChangeEvent(seq ?? change.seq, change);
        } else if (seq != null) {
          yield CursorEvent(seq);
        }
        id = event = '';
        data.clear();
      } else if (line.startsWith(':')) {
        continue; // ping
      } else if (line.startsWith('id:')) {
        id = line.substring(3).trim();
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  void close() => _http.close();
}
