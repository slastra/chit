import 'protocol.dart';

enum Role { owner, editor, viewer, none }

/// [me]'s part in [note]: its owner, an editor or viewer it was shared with,
/// or none.
Role roleOf(Note note, List<Member> members, String me) {
  if (note.owner == me) return Role.owner;
  for (final m in members) {
    if (m.user == me) return m.role == 'viewer' ? Role.viewer : Role.editor;
  }
  return Role.none;
}

/// Whether [role] may change a note's content (title, text, items, files,
/// color). Pin, archive and reminders are each person's own, for anyone.
bool canEdit(Role role) => role == Role.owner || role == Role.editor;
