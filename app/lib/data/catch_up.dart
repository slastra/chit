import 'dart:convert';

import '../core/hlc.dart';
import '../core/protocol.dart';
import 'api.dart';
import 'replica.dart';

/// A signed-in session as saved in the replica, read without Riverpod (the
/// Android background worker and notification actions run in engines of
/// their own). Null when signed out. Never makes a device id.
Future<({String server, String token, Person user, String device})?> readSession(Replica replica) async {
  final server = await replica.meta('server');
  final token = await replica.meta('token');
  final user = await replica.meta('user_json');
  final device = await replica.meta('device');
  if (server == null || token == null || token.isEmpty || user == null || device == null) return null;
  return (server: server, token: token, user: Person.fromJson((jsonDecode(user) as Map).cast()), device: device);
}

/// Applies everything the server has since the replica's cursor, a page at
/// a time. [onChanges] hears each page first, with the library as it was
/// before the page (to describe changes to things the page removes).
/// Returns how many changes were applied.
Future<int> catchUp(
  Replica replica,
  ChitApi api,
  HlcClock clock, {
  Future<void> Function(List<Change> changes, Library before)? onChanges,
}) async {
  var applied = 0;
  var since = await replica.cursor();
  while (true) {
    final page = await api.changes(since);
    if (page.changes.isNotEmpty && onChanges != null) await onChanges(page.changes, await replica.read());
    await replica.applyChanges(page.changes, page.seq);
    for (final c in page.changes) {
      if (c.hlc.isNotEmpty) clock.observe(c.hlc);
    }
    applied += page.changes.length;
    if (!page.more || page.seq <= since) return applied;
    since = page.seq;
  }
}

/// Sends the outbox once, oldest first, in batches; acks what the server
/// answered (applied, stale, or refused). Returns whether any op was
/// refused, which calls for a fresh snapshot.
Future<bool> flushOnce(Replica replica, ChitApi api) async {
  var refused = false;
  while (true) {
    final queued = await replica.pending(limit: 500);
    if (queued.isEmpty) return refused;
    final resp = await api.ops([for (final q in queued) q.op]);
    await replica.ack(queued.map((q) => q.seq));
    if (resp.results.any((r) => r.error != null)) refused = true;
  }
}
