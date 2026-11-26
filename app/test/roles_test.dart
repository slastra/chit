import 'package:chit/core/protocol.dart';
import 'package:chit/core/roles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('who is what on a note', () {
    final note = Note({'id': 'n', 'owner': 'shaun'});
    final members = [
      Member({'note': 'n', 'user': 'angelica', 'role': 'editor'}),
      Member({'note': 'n', 'user': 'angelo', 'role': 'viewer'}),
    ];
    expect(roleOf(note, members, 'shaun'), Role.owner);
    expect(roleOf(note, members, 'angelica'), Role.editor);
    expect(roleOf(note, members, 'angelo'), Role.viewer);
    expect(roleOf(note, members, 'guest'), Role.none);
    expect(canEdit(Role.editor), isTrue);
    expect(canEdit(Role.viewer), isFalse);
  });
}
