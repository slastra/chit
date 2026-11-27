/// Android's background work: a catch-up every 15 minutes or so (new
/// changes, the outbox, reminders, shared-edit notifications), and the
/// Done / Snooze buttons on a reminder. Each runs in an engine of its own,
/// with its own connection to the database (WAL keeps the two apart).
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'core/describe.dart';
import 'core/hlc.dart';
import 'data/api.dart';
import 'data/catch_up.dart';
import 'data/database.dart';
import 'data/replica.dart';
import 'notifications.dart';

const _catchUpTask = 'chit-catchup';
const _flushTask = 'chit-flush';

/// Registers the periodic catch-up (kept as is when already registered).
Future<void> scheduleBackgroundSync() async {
  if (!notificationsSupported) return;
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    _catchUpTask,
    _catchUpTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      await _run(task).timeout(const Duration(minutes: 8));
      return true;
    } on Unauthorized {
      return true; // signed out: nothing to retry until sign-in
    } catch (e) {
      debugPrint('chit background $task: $e');
      return false;
    }
  });
}

Future<void> _run(String task) async {
  // The app in front is live already; in the background it may still be
  // streaming, but a frozen process's stream can't be trusted, so catch
  // up here regardless (notifications are told once, by feed position).
  if (await askApp(const ['foreground']) == true) {
    debugPrint('chit background $task: the app is in front');
    return;
  }
  final db = ChitDb();
  try {
    final replica = Replica(db);
    final session = await readSession(replica);
    if (session == null || await replica.cursor() == 0) return;
    final api = ChitApi(server: session.server, token: session.token, device: session.device);
    try {
      await _refreshToken(replica, api);
      if (task == _catchUpTask) {
        final me = session.user.id;
        Describer? describer;
        if (await activityEnabled(replica)) {
          try {
            await cacheNames(replica, await api.people());
          } catch (_) {
            // last known names will do
          }
        }
        if (await replica.meta('notified_seq') == null) {
          await replica.setMeta('notified_seq', '${await replica.cursor()}');
        }
        final applied = await catchUp(
          replica,
          api,
          HlcClock(session.device),
          onChanges: (changes, before) async {
            describer ??= await describerFor(replica, before, me);
            await notifyActivity(replica, describer!, [for (final c in changes) (c.seq, c)], me);
          },
        );
        debugPrint('chit background $task: $applied changes');
      }
      await flushOnce(replica, api);
      await syncReminders(replica, await replica.read());
    } finally {
      api.close();
    }
  } finally {
    await db.close();
    // the app, if it's running behind, reads what changed under it
    unawaited(askApp(const ['changed']));
  }
}

Future<void> _refreshToken(Replica replica, ChitApi api) async {
  if (await api.refreshIfDue() case final token?) await replica.setMeta('token', token);
}

/// Done or Snooze tapped on a reminder with the app not in front. The
/// running app does it if there is one; otherwise this edits the replica
/// itself, sends it, and leaves the sending to a one-off job if offline.
@pragma('vm:entry-point')
Future<void> notificationActionInBackground(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  final note = noteOfPayload(r.payload);
  final action = r.actionId;
  if (note == null || action == null) return;
  if (await askApp(['action', action, note]) == true) return;
  await initNotifications();
  final db = ChitDb();
  try {
    final replica = Replica(db);
    final session = await readSession(replica);
    if (session == null) return;
    final lib = await replica.read();
    final ops = reminderActionOps(lib, note, action, HlcClock(session.device), DateTime.now());
    if (ops.isEmpty) return;
    await replica.applyLocal(ops, session.user.id);
    // the snoozed alarm is set now, sent or not
    await syncReminders(replica, await replica.read());
    final api = ChitApi(server: session.server, token: session.token, device: session.device);
    try {
      await flushOnce(replica, api).timeout(const Duration(seconds: 6));
    } catch (_) {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerOneOffTask(
        _flushTask,
        _flushTask,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
      );
    } finally {
      api.close();
    }
  } finally {
    await db.close();
  }
}
