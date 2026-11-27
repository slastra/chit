import 'dart:async';
import 'dart:math';

import '../core/hlc.dart';
import '../core/protocol.dart';
import 'api.dart';
import 'catch_up.dart';
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

  /// Hears each change the stream brings, with its feed position, before
  /// it is applied (the phone's shared-edit notifications).
  Future<void> Function(int seq, Change change)? onRemoteChange;

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

  /// A rejected op asked for a fresh snapshot: the stream ends, and the
  /// loop loads one before it streams again.
  bool _resync = false;
  Completer<void>? _streamDone;
  bool _flushAgain = false;
  Timer? _retry;

  void _set(SyncPhase phase, [String error = '']) {
    _current = SyncStatus(phase, error: error);
    if (!_status.isClosed) _status.add(_current);
  }

  /// Builds an op stamped with this device's clock.
  /// [base]: for free text, the clock of the value the edit started from.
  Op op(String collection, String id, String field, Object? value, {String base = ''}) =>
      Op(collection: collection, id: id, field: field, value: value, hlc: clock.now(), base: base);

  /// Applies edits here at once and queues them for the server.
  Future<List<OpResult>> edit(List<Op> ops) async {
    final results = await replica.applyLocal(ops, me);
    unawaited(flush());
    return results;
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    // every clock this replica has seen, in every collection, so an edit
    // here (a reminder's Done, an item checked) is never stamped behind
    // another device's
    (await replica.clocks()).forEach(clock.observe);
    unawaited(_loop());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _uploadRetry?.cancel();
    await _progress.close();
    await _sub?.cancel();
    nudge(); // wakes a sleeping loop, which then sees it is not running
    await _presence.close();
    await _status.close();
  }

  /// Ends the stream so the loop reloads the snapshot (the server refused
  /// an op, which the reload undoes here) and streams from there.
  void _resyncSoon() {
    _resync = true;
    unawaited(_sub?.cancel());
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete();
    nudge();
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
        if (_resync) {
          // Back to a snapshot, then a stream from its seq. Loading one
          // under an open stream would lose a change the stream delivered
          // after the snapshot was taken: the cursor goes back to the
          // snapshot's, and the open stream never sends that change again.
          _resync = false;
          await replica.resetCursor();
        }
        if (await replica.cursor() == 0) await _loadSnapshot();
        // a second resync asked for while the snapshot was in flight
        if (_resync) continue;
        _set(SyncPhase.connecting);
        final done = _streamDone = Completer<void>();
        void fail(Object e) {
          if (!done.isCompleted) done.completeError(e);
          unawaited(_sub?.cancel());
        }

        // Events are handled strictly one batch after another (two batches
        // must never race into the replica), and the changes that arrive
        // together are applied in one transaction: a burst of edits from
        // another device is one new Library, not one per edit.
        final pending = <StreamEvent>[];
        var scheduled = false;
        var tail = Future<void>.value();
        void after(FutureOr<void> Function() step) {
          tail = tail.then((_) => done.isCompleted ? null : step()).catchError(fail);
        }

        _sub = api
            .stream(await replica.cursor())
            .listen(
              (ev) {
                pending.add(ev);
                if (scheduled) return;
                scheduled = true;
                after(() async {
                  // one turn of the event loop: whatever came in the same
                  // read from the socket joins this batch
                  await Future<void>(() {});
                  scheduled = false;
                  final batch = List.of(pending);
                  pending.clear();
                  return _handle(batch, onOpen: () => backoff = const Duration(seconds: 1));
                });
              },
              onError: (Object e) => after(() => fail(e)),
              onDone: () => after(() {
                if (!done.isCompleted) done.complete();
              }),
              cancelOnError: true,
            );
        await done.future;
        // whatever the stream delivered has landed before anything else
        await tail.catchError((_) {});
        if (!_running) return;
        // whoever was here, as far as this stream knew, is not known now
        _forgetPresence();
        // a resync: straight back round, to the snapshot
        if (_resync) continue;
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

  /// Handles stream events in order, applying each run of changes (and
  /// the cursor after it) in one transaction. The remote-change hook still
  /// sees every change, in order, before it is applied.
  Future<void> _handle(List<StreamEvent> events, {required void Function() onOpen}) async {
    final changes = <Change>[];
    var cursor = -1;
    Future<void> apply() async {
      if (changes.isEmpty && cursor < 0) return;
      await replica.applyChanges(List.of(changes), cursor < 0 ? 0 : cursor);
      changes.clear();
      cursor = -1;
    }

    for (final ev in events) {
      switch (ev) {
        case OpenEvent():
          await apply();
          onOpen();
          _set(SyncPhase.online);
          unawaited(flush());
        case ChangeEvent(:final seq, :final change):
          try {
            await onRemoteChange?.call(seq, change);
          } catch (_) {
            // a notification is never worth the stream
          }
          changes.add(change);
          cursor = seq;
          if (change.hlc.isNotEmpty) clock.observe(change.hlc);
        case CursorEvent(:final seq):
          cursor = seq;
        case PresenceEvent():
          _see(ev);
      }
    }
    await apply();
  }

  // ---- presence ----------------------------------------------------------------

  /// Who else has each note open, by note, then by device: from the stream,
  /// so it empties when the stream ends.
  final Map<String, Map<String, ({String user, bool editing})>> _present = {};
  final _presence = StreamController<Map<String, List<({String user, bool editing})>>>.broadcast();

  /// Others in each note, one entry per person (typing if any of their
  /// devices is), as it changes.
  Stream<Map<String, List<({String user, bool editing})>>> get presenceStream => _presence.stream;
  Map<String, List<({String user, bool editing})>> get presence => {
    for (final MapEntry(key: note, value: devices) in _present.entries)
      note: [
        for (final user in {for (final d in devices.values) d.user})
          (user: user, editing: devices.values.any((d) => d.user == user && d.editing)),
      ],
  };

  void _see(PresenceEvent ev) {
    if (ev.user == me) return;
    final devices = _present[ev.note] ??= {};
    if (ev.gone) {
      devices.remove(ev.device);
      if (devices.isEmpty) _present.remove(ev.note);
    } else {
      devices[ev.device] = (user: ev.user, editing: ev.editing);
    }
    if (!_presence.isClosed) _presence.add(presence);
  }

  void _forgetPresence() {
    if (_present.isEmpty) return;
    _present.clear();
    if (!_presence.isClosed) _presence.add(presence);
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
    try {
      if (await api.refreshIfDue() case final token?) onToken?.call(token);
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
        if (_running && await flushOnce(replica, api)) _resyncSoon();
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
