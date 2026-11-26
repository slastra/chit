/// The phone's notifications: reminders as exact alarms, other people's
/// edits grouped per person and note. Android only; everything here is a
/// no-op elsewhere (chitd notifies on the desk). Safe to use from any
/// isolate: the app, the background worker, a notification action.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Person;
import 'package:timezone/timezone.dart' as tz;

import 'core/describe.dart';
import 'core/hlc.dart';
import 'core/notify_plan.dart';
import 'core/protocol.dart';
import 'core/reminders.dart';
import 'data/replica.dart';

bool get notificationsSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

final _plugin = FlutterLocalNotificationsPlugin();
AndroidFlutterLocalNotificationsPlugin? get _android =>
    _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

const _reminders = AndroidNotificationChannel(
  'reminders',
  'Reminders',
  description: 'Reminders you set on notes',
  importance: Importance.high,
);
const _activity = AndroidNotificationChannel(
  'activity',
  'Shared edits',
  description: 'What other people change on notes shared with you',
);
const _activityGroup = 'us.lastra.chit.activity';

/// The payload a notification carries: the note it opens.
String? noteOfPayload(String? payload) => payload != null && payload.startsWith('note:') ? payload.substring(5) : null;

/// Sets the plugin up in this isolate. [onResponse] hears taps (and
/// actions, when the app is in front); actions in the background go to
/// [onBackground], a top-level entry point.
Future<void> initNotifications({
  DidReceiveNotificationResponseCallback? onResponse,
  DidReceiveBackgroundNotificationResponseCallback? onBackground,
}) async {
  if (!notificationsSupported) return;
  await _plugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
    onDidReceiveNotificationResponse: onResponse,
    onDidReceiveBackgroundNotificationResponse: onBackground,
  );
  await _android?.createNotificationChannel(_reminders);
  await _android?.createNotificationChannel(_activity);
}

/// The note a notification tap started the app with, if it did.
Future<String?> launchedFromNote() async {
  if (!notificationsSupported) return null;
  final details = await _plugin.getNotificationAppLaunchDetails();
  if (details == null || !details.didNotificationLaunchApp) return null;
  return noteOfPayload(details.notificationResponse?.payload);
}

/// Asks to post notifications (Android 13+), once it matters.
Future<void> askNotificationPermission() async {
  if (!notificationsSupported) return;
  await _android?.requestNotificationsPermission();
}

// ---- reminders -----------------------------------------------------------

NotificationDetails _reminderDetails(String body) => NotificationDetails(
  android: AndroidNotificationDetails(
    _reminders.id,
    _reminders.name,
    channelDescription: _reminders.description,
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
    styleInformation: body.isEmpty ? null : BigTextStyleInformation(body),
    actions: const [AndroidNotificationAction('done', 'Done'), AndroidNotificationAction('snooze', 'Snooze 10 min')],
  ),
);

int reminderId(String note) => notificationId('r:$note');

Future<ReminderLedger> _ledger(Replica replica) async {
  final raw = await replica.meta('notify_reminders');
  if (raw == null || raw.isEmpty) return {};
  final m = (jsonDecode(raw) as Map).cast<String, Object?>();
  return {
    for (final MapEntry(:key, :value) in m.entries)
      key: (reminder: (value! as Map)['r']! as String, sig: (value as Map)['s']! as String),
  };
}

Future<void> _saveLedger(Replica replica, ReminderLedger l) => replica.setMeta(
  'notify_reminders',
  jsonEncode({
    for (final MapEntry(:key, :value) in l.entries) key: {'r': value.reminder, 's': value.sig},
  }),
);

/// Brings the scheduled alarms in line with the library's reminders.
Future<void> syncReminders(Replica replica, Library lib) async {
  if (!notificationsSupported) return;
  final plan = planReminders(lib, await _ledger(replica), DateTime.now());
  for (final note in plan.cancel) {
    await _plugin.cancel(id: reminderId(note));
  }
  if (plan.schedule.isNotEmpty) {
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    for (final r in plan.schedule) {
      await _plugin.zonedSchedule(
        id: reminderId(r.note),
        title: r.title,
        body: r.body,
        // UTC on the wire and here: a change of time zone moves nothing
        scheduledDate: tz.TZDateTime.from(r.at.toUtc(), tz.UTC),
        notificationDetails: _reminderDetails(r.body),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'note:${r.note}',
      );
    }
  }
  for (final r in plan.show) {
    await _plugin.show(
      id: reminderId(r.note),
      title: r.title,
      body: r.body,
      notificationDetails: _reminderDetails(r.body),
      payload: 'note:${r.note}',
    );
  }
  await _saveLedger(replica, plan.next);
}

/// Done or Snooze on a reminder, as edits to this person's note state,
/// stamped after every clock the replica has seen for it.
List<Op> reminderActionOps(Library lib, String note, String action, HlcClock clock, DateTime now) {
  lib.stateOf(note).clocks.values.forEach(clock.observe);
  Op op(String field, Object? value) =>
      Op(collection: Collections.noteState, id: note, field: field, value: value, hlc: clock.now());
  return switch (action) {
    'done' => [op('reminder_done', true)],
    'snooze' => [op('reminder', reminderWire(now.add(const Duration(minutes: 10)))), op('reminder_done', false)],
    _ => const [],
  };
}

// ---- other people's edits ------------------------------------------------

/// Whether this device notifies about other people's edits (on unless
/// turned off in the account menu).
Future<bool> activityEnabled(Replica replica) async => await replica.meta('notify_activity') != 'off';

Future<void> setActivityEnabled(Replica replica, bool on) async {
  await replica.setMeta('notify_activity', on ? 'on' : 'off');
  if (!on) await clearActivity(replica);
}

/// Display names by user id, as last fetched (cached for the worker).
Future<Map<String, String>> cachedNames(Replica replica) async {
  final raw = await replica.meta('people');
  if (raw == null || raw.isEmpty) return {};
  return {
    for (final p in (jsonDecode(raw) as List).cast<Map<Object?, Object?>>())
      p['id']! as String: Person.fromJson(p.cast()).display,
  };
}

Future<void> cacheNames(Replica replica, List<Person> people) =>
    replica.setMeta('people', jsonEncode([for (final p in people) p.toJson()]));

/// A Describer started from [lib], as the change feed will next find it.
Future<Describer> describerFor(Replica replica, Library lib, String me) async => Describer(
  notes: lib.notes,
  items: [for (final l in lib.items.values) ...l],
  members: [for (final l in lib.members.values) ...l],
  attachments: [for (final l in lib.attachments.values) ...l],
  names: await cachedNames(replica),
  me: me,
);

/// Feeds [changes] (with their feed positions) to [d], and notifies about
/// other people's edits not notified before: each change is told once,
/// whichever isolate sees it first.
Future<void> notifyActivity(Replica replica, Describer d, List<(int seq, Change c)> changes, String me) async {
  final seen = int.tryParse(await replica.meta('notified_seq') ?? '') ?? 0;
  final events = <({String by, String note, String sentence})>[];
  var top = seen;
  for (final (seq, c) in changes) {
    final note = d.noteOf(c);
    final sentence = d.describe(c);
    if (seq <= seen) continue;
    if (seq > top) top = seq;
    if (c.by.isEmpty || c.by == me || sentence.isEmpty) continue;
    events.add((by: c.by, note: note, sentence: sentence));
  }
  if (top > seen) await replica.setMeta('notified_seq', '$top');
  if (events.isEmpty || !notificationsSupported || !await activityEnabled(replica)) return;
  final pending = await _pendingActivity(replica);
  final groups = groupActivity(events, pending: pending);
  for (final g in groups) {
    final key = '${g.by}/${g.note}';
    pending[key] = g.lines;
    final body = activityBody(g.lines);
    await _plugin.show(
      id: notificationId('a:$key'),
      title: d.title(g.note),
      body: body,
      payload: 'note:${g.note}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _activity.id,
          _activity.name,
          channelDescription: _activity.description,
          groupKey: _activityGroup,
          onlyAlertOnce: true,
          category: AndroidNotificationCategory.social,
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
    );
  }
  if (pending.length > 1) {
    await _plugin.show(
      id: notificationId('a:summary'),
      title: 'chit',
      body: '${pending.length} notes changed',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _activity.id,
          _activity.name,
          groupKey: _activityGroup,
          setAsGroupSummary: true,
          onlyAlertOnce: true,
        ),
      ),
    );
  }
  await replica.setMeta('notify_pending', jsonEncode(pending));
}

Future<Map<String, List<String>>> _pendingActivity(Replica replica) async {
  final raw = await replica.meta('notify_pending');
  if (raw == null || raw.isEmpty) return {};
  return {
    for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).cast<String, Object?>().entries)
      key: [...(value! as List).cast<String>()],
  };
}

/// Takes back the shared-edit notifications (the app is in front, where
/// the edits show for themselves).
Future<void> clearActivity(Replica replica) async {
  if (!notificationsSupported) return;
  final pending = await _pendingActivity(replica);
  for (final key in pending.keys) {
    await _plugin.cancel(id: notificationId('a:$key'));
  }
  await _plugin.cancel(id: notificationId('a:summary'));
  await replica.setMeta('notify_pending', '{}');
}

// ---- the app's isolate, from the others ----------------------------------

/// The app's isolate registers this port while it runs, so the worker and
/// notification actions can hand it their work.
const uiPortName = 'chit/ui';

/// Sends [message] to the app's isolate and waits for its answer; null when
/// the app isn't running (or didn't answer in time).
Future<Object?> askApp(List<Object?> message, {Duration timeout = const Duration(seconds: 2)}) async {
  final port = IsolateNameServer.lookupPortByName(uiPortName);
  if (port == null) return null;
  final reply = ReceivePort();
  try {
    port.send([...message, reply.sendPort]);
    return await reply.first.timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    reply.close();
  }
}
