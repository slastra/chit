import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hlc.dart';
import '../core/protocol.dart';
import '../data/api.dart';
import '../data/database.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../data/replica.dart';
import '../data/sync.dart';

final _rand = Random.secure();
const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// A random string of [n] characters from [a-z0-9].
String randomId([int n = 15]) =>
    String.fromCharCodes(List.generate(n, (_) => _alphabet.codeUnitAt(_rand.nextInt(_alphabet.length))));

/// The local database, one for the app's life.
final dbProvider = Provider<ChitDb>((ref) {
  final db = ChitDb();
  ref.onDispose(db.close);
  return db;
});

final replicaProvider = Provider<Replica>((ref) => Replica(ref.watch(dbProvider)));

/// A signed-in session. Kept in the replica's own database (its meta table),
/// which is private to the app on every platform.
typedef Session = ({String server, String token, Person user, String device});

final sessionProvider = AsyncNotifierProvider<SessionNotifier, Session?>(SessionNotifier.new);

final class SessionNotifier extends AsyncNotifier<Session?> {
  Replica get _replica => ref.read(replicaProvider);

  @override
  Future<Session?> build() async {
    final server = await _replica.meta('server');
    final token = await _replica.meta('token');
    final user = await _replica.meta('user_json');
    if (server == null || token == null || token.isEmpty || user == null) return null;
    return (
      server: server,
      token: token,
      user: Person.fromJson((jsonDecode(user) as Map).cast()),
      device: await _device(),
    );
  }

  /// This install's device id, made once. The server uses it to leave this
  /// device's own edits out of its feed.
  Future<String> _device() async {
    final d = await _replica.meta('device');
    if (d != null) return d;
    final fresh = 'a${randomId(7)}';
    await _replica.setMeta('device', fresh);
    return fresh;
  }

  Future<void> signIn(String server, String email, String password) async {
    final api = ChitApi(server: server);
    final r = await api.login(email.trim(), password);
    api.close();
    // Another account or server: start from a clean replica.
    if (await _replica.meta('server') != api.server || await _replica.meta('user') != r.user.id) {
      await _replica.wipe();
    }
    await _replica.setMeta('server', api.server);
    await _replica.setMeta('user', r.user.id);
    await _replica.setMeta('user_json', jsonEncode(r.user.toJson()));
    await _replica.setMeta('token', r.token);
    state = AsyncData((server: api.server, token: r.token, user: r.user, device: await _device()));
  }

  Future<void> saveToken(String token) async {
    await _replica.setMeta('token', token);
    if (state.value case final s?) state = AsyncData((server: s.server, token: token, user: s.user, device: s.device));
  }

  /// Signs out but keeps the replica, so signing back in is instant.
  Future<void> signOut() async {
    await _replica.setMeta('token', '');
    state = const AsyncData(null);
  }
}

/// Who is signed in where, without the token: what the engine and the
/// people list are for. A refreshed token changes the session but not
/// this, so neither starts over (the engine keeps its own token current).
final _account = Provider<({String server, String user, String device})?>((ref) {
  final s = ref.watch(sessionProvider).value;
  return s == null ? null : (server: s.server, user: s.user.id, device: s.device);
});

/// The sync engine for the current session; replaced on sign-in, stopped
/// on sign-out.
final engineProvider = Provider<SyncEngine?>((ref) {
  if (ref.watch(_account) == null) return null;
  final session = ref.read(sessionProvider).value!;
  final engine = SyncEngine(
    replica: ref.watch(replicaProvider),
    api: ChitApi(server: session.server, token: session.token, device: session.device),
    me: session.user.id,
    clock: HlcClock(session.device),
    onToken: (t) => unawaited(ref.read(sessionProvider.notifier).saveToken(t)),
    openUpload: files.openUpload,
    removeCopy: files.removeCopy,
    onUploadFailed: (name, reason) => uploadFailures.add("Couldn't attach $name: $reason"),
  );
  unawaited(engine.start());
  ref.onDispose(() {
    engine.api.close();
    unawaited(engine.stop());
  });
  return engine;
});

/// Files the server turned away, as messages for a snackbar (the app shows
/// them; the engine has no UI).
final uploadFailures = StreamController<String>.broadcast();

/// Attachments for viewing, for the current session.
final mediaProvider = Provider<Media?>((ref) {
  final engine = ref.watch(engineProvider);
  return engine == null ? null : Media(engine.api, ref.watch(replicaProvider));
});

/// How far each running upload has got, 0 to 1, by attachment id.
final uploadProgressProvider = StreamProvider<Map<String, double>>((ref) async* {
  final engine = ref.watch(engineProvider);
  if (engine == null) return;
  yield engine.uploads;
  yield* engine.uploadProgress;
});

/// Attaches [picked] to [note] (which must exist locally already): each
/// file shows at once as pending and uploads when the server can take it.
/// Returns the names of files over the size limit, which are left out.
Future<List<String>> attachFiles(Replica replica, SyncEngine? engine, String note, List<NewFile> picked) async {
  final tooBig = <String>[];
  for (final f in picked) {
    if (f.size > maxAttachmentSize) {
      tooBig.add(f.name);
      continue;
    }
    final id = randomId();
    final path = files.hasFiles ? await files.keepCopy(id, f.name, from: f.path, bytes: f.bytes) : null;
    await replica.queueUpload(
      id: id,
      note: note,
      name: f.name,
      type: guessType(f.name),
      size: f.size,
      path: path,
      bytes: files.hasFiles ? null : f.bytes,
    );
  }
  unawaited(engine?.sendUploads());
  return tooBig;
}

final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final engine = ref.watch(engineProvider);
  if (engine == null) return;
  yield engine.status;
  yield* engine.statusStream;
});

/// Everything in the replica, live.
final libraryProvider = StreamProvider<Library>((ref) => ref.watch(replicaProvider).watch());

final pendingProvider = StreamProvider<int>((ref) => ref.watch(replicaProvider).watchPendingCount());

/// The accounts on the server, for names and sharing.
final peopleProvider = FutureProvider<List<Person>>((ref) async {
  if (ref.watch(_account) == null) return const [];
  final session = ref.read(sessionProvider).value!;
  final api = ChitApi(server: session.server, token: session.token);
  try {
    return await api.people();
  } finally {
    api.close();
  }
});
