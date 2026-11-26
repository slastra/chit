import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Person;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../background.dart';
import '../core/describe.dart';
import '../core/protocol.dart';
import '../data/replica.dart';
import '../data/sync.dart';
import '../notifications.dart';
import '../state/providers.dart';

/// The app's side of the phone's notifications (Android; nothing
/// elsewhere): keeps reminder alarms in step with the notes, tells of
/// other people's edits while the app is out of sight, opens a note from a
/// tap, and answers the background worker and the reminder buttons when
/// the app is running.
final class PhoneNotifications {
  PhoneNotifications(this.ref, {required this.open});

  final WidgetRef ref;

  /// Opens a note (a notification was tapped).
  final void Function(String note) open;

  ReceivePort? _port;
  AppLifecycleListener? _lifecycle;
  Timer? _plan;
  Describer? _describer;
  final _subs = <ProviderSubscription<void>>[];

  Future<void> start() async {
    if (!notificationsSupported) return;
    await initNotifications(onResponse: _response, onBackground: notificationActionInBackground);
    final port = _port = ReceivePort();
    IsolateNameServer.removePortNameMapping(uiPortName);
    IsolateNameServer.registerPortWithName(port.sendPort, uiPortName);
    port.listen(_message);
    _lifecycle = AppLifecycleListener(onHide: _hidden, onResume: _resumed);
    // reminders follow the notes, a beat after the last change
    _subs.add(
      ref.listenManual<AsyncValue<Library>>(libraryProvider, (_, next) {
        if (!next.hasValue) return;
        _plan?.cancel();
        _plan = Timer(const Duration(seconds: 1), () {
          unawaited(syncReminders(ref.read(replicaProvider), next.requireValue));
        });
      }, fireImmediately: true),
    );
    _subs.add(ref.listenManual<SyncEngine?>(engineProvider, (_, engine) => _hook(engine), fireImmediately: true));
    _subs.add(
      ref.listenManual<AsyncValue<List<Person>>>(peopleProvider, (_, next) {
        if (next.value case final people? when people.isNotEmpty) {
          unawaited(cacheNames(ref.read(replicaProvider), people));
        }
      }, fireImmediately: true),
    );
    // once signed in, ask to notify (Android 13+ asks the person once)
    _subs.add(
      ref.listenManual<AsyncValue<Session?>>(sessionProvider, (_, next) async {
        if (next.value == null) return;
        final replica = ref.read(replicaProvider);
        if (await replica.meta('asked_notifications') != null) return;
        await replica.setMeta('asked_notifications', '1');
        await askNotificationPermission();
      }, fireImmediately: true),
    );
    unawaited(scheduleBackgroundSync());
    if (await launchedFromNote() case final note?) open(note);
  }

  void stop() {
    _plan?.cancel();
    for (final s in _subs) {
      s.close();
    }
    _lifecycle?.dispose();
    _port?.close();
    if (_port != null) IsolateNameServer.removePortNameMapping(uiPortName);
  }

  /// Hears the stream's changes while the app is out of sight.
  void _hook(SyncEngine? engine) {
    engine?.onRemoteChange = (seq, change) async {
      final d = _describer;
      final me = ref.read(sessionProvider).value?.user.id;
      if (d == null || me == null) return;
      await notifyActivity(ref.read(replicaProvider), d, [(seq, change)], me);
    };
  }

  Future<void> _hidden() async {
    final me = ref.read(sessionProvider).value?.user.id;
    if (me == null) return;
    final replica = ref.read(replicaProvider);
    // what was on screen isn't news
    await replica.setMeta('notified_seq', '${await replica.cursor()}');
    _describer = await describerFor(replica, await replica.read(), me);
  }

  Future<void> _resumed() async {
    _describer = null;
    final db = ref.read(dbProvider);
    // the worker may have written underneath
    db.markTablesUpdated([db.records, db.outbox, db.meta, db.uploads]);
    ref.read(engineProvider)?.nudge();
    await clearActivity(ref.read(replicaProvider));
  }

  void _response(NotificationResponse r) {
    final note = noteOfPayload(r.payload);
    if (note == null) return;
    if (r.actionId case final action?) {
      unawaited(_action(action, note));
    } else {
      open(note);
    }
  }

  Future<bool> _action(String action, String note) async {
    final engine = ref.read(engineProvider);
    if (engine == null) return false;
    final lib = await ref.read(replicaProvider).read();
    final ops = reminderActionOps(lib, note, action, engine.clock, DateTime.now());
    if (ops.isNotEmpty) await engine.edit(ops);
    return true;
  }

  Future<void> _message(Object? m) async {
    if (m is! List || m.isEmpty || m.last is! SendPort) return;
    final reply = m.last as SendPort;
    switch (m.first) {
      case 'foreground':
        // asked live: an app started behind the lock screen never was in front
        reply.send(WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
      case 'changed':
        final db = ref.read(dbProvider);
        db.markTablesUpdated([db.records, db.outbox, db.meta]);
        ref.read(engineProvider)?.nudge();
        reply.send(true);
      case 'action' when m.length == 4:
        reply.send(await _action(m[1] as String, m[2] as String));
      default:
        reply.send(null);
    }
  }
}
