import 'dart:async';
import 'dart:math';

import '../core/hlc.dart';
import '../core/protocol.dart';
import 'api.dart';
import 'database.dart';
import 'replica.dart';

enum SyncPhase { connecting, online, offline, signedOut }

final class SyncStatus {
  const SyncStatus(this.phase, {this.error = ''});
  final SyncPhase phase;
  final String error;
}

/// Keeps the replica in step with the server: a snapshot the first time,
/// then the change stream from the saved cursor, and the outbox drained
/// whenever the server answers. The same job chitd does on the desktop.
final class SyncEngine {
  SyncEngine({
    required this.replica,
    required this.api,
    required this.me,
    required this.clock,
    this.onToken,
    this.openUpload,
    this.removeCopy,
    this.onUploadFailed,
  });

  final Replica replica;
  final ChitApi api;
  final String me;
  final HlcClock clock;

  /// Called with a refreshed token, to persist it.
  final void Function(String token)? onToken;

  /// Reads a queued file for upload, and drops its local copy after; the
  /// platform's file layer (local_files.dart) supplies both.
  final Future<({Stream<List<int>> stream, int length})> Function(Upload u)? openUpload;
  final Future<void> Function(Upload u)? removeCopy;

  /// A file the server turned away (too large, no longer allowed), with why.
  final void Function(String name, String reason)? onUploadFailed;

  /// How far each running upload has got, 0 to 1, by attachment id.
  final _progress = StreamController<Map<String, double>>.broadcast();
  final Map<String, double> _uploading = {};
  Stream<Map<String, double>> get uploadProgress => _progress.stream;
  Map<String, double> get uploads => Map.unmodifiable(_uploading);
  bool _sending = false;
  Timer? _uploadRetry;

  final _status = StreamController<SyncStatus>.broadcast();
  SyncStatus _current = const SyncStatus(SyncPhase.connecting);
  SyncStatus get status => _current;
  Stream<SyncStatus> get statusStream => _status.stream;

  bool _running = false;
  StreamSubscription<void>? _sub;
  Completer<void>? _wake;
  bool _flushing = false;
  bool _flushAgain = false;
  Timer? _retry;

  void _set(SyncPhase phase, [String error = '']) {
    _current = SyncStatus(phase, error: error);
    if (!_status.isClosed) _status.add(_current);
  }

  /// Builds an op stamped with this device's clock.
  Op op(String collection, String id, String field, Object? value) =>
      Op(collection: collection, id: id, field: field, value: value, hlc: clock.now());

  /// Applies edits here at once and queues them for the server.
  Future<List<OpResult>> edit(List<Op> ops) async {
    final results = await replica.applyLocal(ops, me);
    unawaited(flush());
    return results;
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    for (final n in (await replica.read()).notes) {
      n.clocks.values.forEach(clock.observe);
    }
    unawaited(_loop());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _uploadRetry?.cancel();
    await _progress.close();
    await _sub?.cancel();
    _wake?.complete();
    await _status.close();
  }

  /// Reconnects right away (the app came back to the foreground, the
  /// network returned).
  void nudge() {
    if (_wake case final w? when !w.isCompleted) w.complete();
  }

  Future<void> _loop() async {
    var backoff = const Duration(seconds: 1);
    await _refreshToken();
    while (_running) {
      try {
        if (await replica.cursor() == 0) await _loadSnapshot();
        _set(SyncPhase.connecting);
        final done = Completer<void>();
        // asyncMap applies events strictly one after another: an async
        // listen callback would let two changes race into the replica.
        _sub = api
            .stream(await replica.cursor())
            .asyncMap<void>((ev) async {
              switch (ev) {
                case OpenEvent():
                  backoff = const Duration(seconds: 1);
                  _set(SyncPhase.online);
                  unawaited(flush());
                case ChangeEvent(:final seq, :final change):
                  await replica.applyChanges([change], seq);
                  if (change.hlc.isNotEmpty) clock.observe(change.hlc);
                case CursorEvent(:final seq):
                  await replica.applyChanges(const [], seq);
              }
            })
            .listen(
              null,
              onError: (Object e) {
                if (!done.isCompleted) done.completeError(e);
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              cancelOnError: true,
            );
        await done.future;
        if (!_running) return;
        _set(SyncPhase.offline, 'disconnected');
      } on Unauthorized {
        _set(SyncPhase.signedOut, 'signed out');
        _running = false;
        return;
      } catch (e) {
        if (!_running) return;
        _set(SyncPhase.offline, _reason(e));
      }
      _wake = Completer<void>();
      await Future.any([Future<void>.delayed(backoff), _wake!.future]);
      backoff = Duration(seconds: min(backoff.inSeconds * 2, 15));
    }
  }

  static String _reason(Object e) => switch (e) {
    TimeoutException() => 'the server stopped answering',
    ApiError(:final message) => message,
    _ => "can't reach the server",
  };

  Future<void> _loadSnapshot() async {
    final s = await api.snapshot();
    await replica.replaceAll(s);
    for (final list in s.records.values) {
      for (final rec in list) {
        ((rec['clocks'] as Map?) ?? const {}).values.whereType<String>().forEach(clock.observe);
      }
    }
  }

  Future<void> _refreshToken() async {
    final exp = ChitApi.tokenExpiry(api.token);
    if (exp == null || exp.difference(DateTime.now()) > const Duration(days: 3)) return;
    try {
      final r = await api.refresh();
      api.token = r.token;
      onToken?.call(r.token);
    } on Unauthorized {
      _set(SyncPhase.signedOut, 'signed out');
      _running = false;
    } catch (_) {
      // offline: try again on the next start
    }
  }

  void _report(String id, double? fraction) {
    if (fraction == null) {
      _uploading.remove(id);
    } else {
      _uploading[id] = fraction;
    }
    if (!_progress.isClosed) _progress.add(Map.unmodifiable(_uploading));
  }

  /// Uploads queued files one at a time, oldest first, once the outbox is
  /// empty (a file's note has to reach the server before the file). A file
  /// the server refuses leaves the queue, and [onUploadFailed] hears why;
  /// anything else (offline, a timeout) retries later.
  Future<void> sendUploads() async {
    final open = openUpload;
    if (_sending || open == null) return;
    _sending = true;
    try {
      while (_running) {
        if ((await replica.pending(limit: 1)).isNotEmpty) return; // flush() calls back
        final queue = await replica.uploads();
        if (queue.isEmpty) return;
        final u = queue.first;
        _report(u.id, 0);
        final ({Stream<List<int>> stream, int length}) file;
        try {
          file = await open(u);
        } catch (_) {
          // the local copy is gone: nothing left to send
          await replica.dropUpload(u.id);
          _report(u.id, null);
          onUploadFailed?.call(u.name, 'the file is no longer on this device');
          continue;
        }
        try {
          final r = await api.upload(
            u.note,
            u.id,
            u.name,
            file.stream,
            file.length,
            onProgress: (sent) => _report(u.id, file.length == 0 ? 1 : sent / file.length),
          );
          await replica.finishUpload(r.attachment);
          await removeCopy?.call(u);
        } on ApiError catch (e) {
          // turned away for good: too large, the note gone, no longer an
          // editor; busy or throttled answers are worth another try
          if (e.status >= 400 && e.status < 500 && e.status != 408 && e.status != 429) {
            await replica.dropUpload(u.id);
            await removeCopy?.call(u);
            onUploadFailed?.call(u.name, e.message);
          } else {
            rethrow;
          }
        } finally {
          _report(u.id, null);
        }
      }
    } on Unauthorized {
      _set(SyncPhase.signedOut, 'signed out');
    } catch (_) {
      _uploadRetry?.cancel();
      _uploadRetry = Timer(const Duration(seconds: 15), () => unawaited(sendUploads()));
    } finally {
      _sending = false;
    }
  }

  /// Sends the outbox, oldest first, until it is empty or the server stops
  /// answering (then retries on a timer). A rejected op is dropped and the
  /// replica reloads, which undoes it here.
  Future<void> flush() async {
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      do {
        _flushAgain = false;
        while (_running) {
          final queued = await replica.pending(limit: 500);
          if (queued.isEmpty) break;
          final resp = await api.ops([for (final q in queued) q.op]);
          await replica.ack(queued.map((q) => q.seq));
          if (resp.results.any((r) => r.error != null)) await _loadSnapshot();
        }
      } while (_flushAgain && _running);
      // the notes now exist on the server, so their files can follow
      if (_running) unawaited(sendUploads());
    } on Unauthorized {
      _set(SyncPhase.signedOut, 'signed out');
    } catch (_) {
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 10), () => unawaited(flush()));
    } finally {
      _flushing = false;
    }
  }
}
