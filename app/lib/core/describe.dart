/// Change-feed entries as short sentences: a port of chit's
/// internal/describe, for the phone's activity notifications. Both are
/// checked against internal/describe/testdata, so the desk's toasts and the
/// phone's notifications say the same thing.
library;

import 'protocol.dart';

/// A note's title as the feed names it (Go's notes.Title): its title, or
/// the first line of its text, cut at 40 characters, or "(untitled)".
String feedTitle(Note n) {
  if (n.title.isNotEmpty) return n.title;
  var body = n.body.trim();
  final nl = body.indexOf('\n');
  if (nl >= 0) body = body.substring(0, nl);
  if (body.length > 40) body = '${body.substring(0, 40)}…';
  return body.isEmpty ? '(untitled)' : body;
}

/// Go's %q for plain text: double-quoted, quotes and backslashes escaped.
String _q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Turns feed changes into sentences, tracking titles and item text so
/// later changes can name what they touch. Feed it every change in order,
/// even ones whose sentence is not shown.
final class Describer {
  Describer({
    required List<Note> notes,
    required List<Item> items,
    required List<Member> members,
    required List<Attachment> attachments,
    required this.names,
    required this.me,
  }) {
    for (final n in notes) {
      _titles[n.id] = feedTitle(n);
    }
    for (final a in attachments) {
      _files[a.id] = a;
    }
    for (final m in members) {
      _shares[m.id] = m;
    }
    for (final it in items) {
      _items[it.id] = (note: it.note, text: it.text);
    }
  }

  /// user id -> display name; [me] is called "You".
  final Map<String, String> names;
  final String me;
  final _titles = <String, String>{};
  final _items = <String, ({String note, String text})>{};
  final _shares = <String, Member>{};
  final _files = <String, Attachment>{};

  String who(String id) => id == me ? 'You' : names[id] ?? 'Someone';
  String title(String note) => _titles[note] ?? 'a note';

  /// Which note a change belongs to, as far as this knows, for grouping.
  String noteOf(Change c) {
    Json value() => (c.value as Map?)?.cast<String, Object?>() ?? const {};
    switch (c.collection) {
      case Collections.notes || Collections.noteState:
        return c.record;
      case Collections.items:
        return c.kind == ChangeKind.record ? Item(value()).note : _items[c.record]?.note ?? '';
      case Collections.attachments:
        return c.kind == ChangeKind.record ? Attachment(value()).note : _files[c.record]?.note ?? '';
      case Collections.members:
        return _shares[c.record]?.note ?? Member(value()).note;
    }
    return '';
  }

  /// The sentence for [c], or "" for one not worth a line (a record this
  /// already knew, a reorder of nothing new).
  String describe(Change c) {
    final w = who(c.by);
    String str() => c.value is String ? c.value! as String : '';
    final truthy = c.value == true;
    Json value() => (c.value as Map?)?.cast<String, Object?>() ?? const {};

    switch (c.kind) {
      case ChangeKind.revoke:
        final t = title(c.record);
        _titles.remove(c.record);
        return 'You no longer have access to $t';
      case ChangeKind.remove:
        final m = _shares.remove(c.record);
        if (m == null) return '$w removed someone from a shared note';
        if (m.user == c.by) return '$w left ${title(m.note)}';
        return '$w stopped sharing ${title(m.note)} with ${who(m.user)}';
      case ChangeKind.record:
        switch (c.collection) {
          case Collections.notes:
            final n = Note(value());
            final known = _titles.containsKey(n.id);
            _titles[n.id] = feedTitle(n);
            if (known) return '';
            return '$w: new ${n.isList ? 'list' : 'note'} ${_q(feedTitle(n))}';
          case Collections.items:
            final it = Item(value());
            final known = _items.containsKey(it.id);
            _items[it.id] = (note: it.note, text: it.text);
            if (known) return '';
            return '$w added ${_q(it.text)} to ${title(it.note)}';
          case Collections.attachments:
            final a = Attachment(value());
            final known = _files.containsKey(a.id);
            _files[a.id] = a;
            if (known) return '';
            return '$w attached ${a.name} to ${title(a.note)}';
          case Collections.noteState:
            final st = NoteState(value());
            if (st.pinned) return '$w pinned ${title(st.note)}';
            if (st.archived) return '$w archived ${title(st.note)}';
            if (st.reminder.isNotEmpty) return '$w set a reminder on ${title(st.note)}';
            return '';
          case Collections.members:
            final m = Member(value());
            final prev = _shares[m.id];
            if (prev != null && prev.role == m.role) return ''; // a new member's copy of a share already announced
            _shares[m.id] = m;
            return '$w shared ${title(m.note)} with ${who(m.user)} (${m.role})';
        }
      case ChangeKind.set:
        switch (c.collection) {
          case Collections.notes:
            final t = title(c.record);
            switch (c.field) {
              case 'title':
                _titles[c.record] = str();
                return '$w renamed $t to ${_q(str())}';
              case 'body':
                return '$w edited $t';
              case 'color':
                return '$w colored $t ${str()}';
              case 'trashed':
                return str().isEmpty ? '$w restored $t' : '$w moved $t to the trash';
              case 'deleted':
                return '$w deleted $t';
            }
          case Collections.items:
            final it = _items[c.record] ?? (note: '', text: '');
            final t = title(it.note);
            switch (c.field) {
              case 'checked':
                return truthy ? '$w checked ${_q(it.text)} in $t' : '$w unchecked ${_q(it.text)} in $t';
              case 'text':
                _items[c.record] = (note: it.note, text: str());
                return '$w changed ${_q(it.text)} to ${_q(str())} in $t';
              case 'deleted':
                if (truthy) return '$w removed ${_q(it.text)} from $t';
              case 'order' || 'indent':
                return '$w rearranged $t';
            }
          case Collections.attachments:
            if (c.field == 'deleted' && truthy) {
              final a = _files[c.record];
              return '$w removed ${a?.name ?? ''} from ${title(a?.note ?? '')}';
            }
          case Collections.noteState:
            final t = title(c.record);
            switch (c.field) {
              case 'pinned':
                return truthy ? '$w pinned $t' : '$w unpinned $t';
              case 'archived':
                return truthy ? '$w archived $t' : '$w unarchived $t';
              case 'reminder':
                return '$w set a reminder on $t';
            }
        }
    }
    return '';
  }
}
