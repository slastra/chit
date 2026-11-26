import 'dart:convert';
import 'dart:io';

import 'package:chit/core/describe.dart';
import 'package:chit/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same fixture and sentences as chit's internal/describe test: the
/// phone's notifications must say what the desk's toasts say.
void main() {
  test('sentences match the Go describer', () {
    final dir = '../internal/describe/testdata';
    final fx = jsonDecode(File('$dir/fixture.json').readAsStringSync()) as Map<String, Object?>;
    final want = (jsonDecode(File('$dir/sentences.json').readAsStringSync()) as List).cast<Map<String, Object?>>();
    final snap = (fx['snapshot']! as Map).cast<String, Object?>();
    List<Json> list(String k) => [
      ...((snap[k] as List?) ?? const []).cast<Map<Object?, Object?>>().map((m) => m.cast<String, Object?>()),
    ];
    final d = Describer(
      notes: list('notes').map(Note.new).toList(),
      items: list('items').map(Item.new).toList(),
      members: list('members').map(Member.new).toList(),
      attachments: list('attachments').map(Attachment.new).toList(),
      names: (fx['names']! as Map).cast<String, String>(),
      me: fx['me']! as String,
    );
    final changes = (fx['changes']! as List).cast<Map<Object?, Object?>>().map((m) => Change.fromJson(m.cast()));
    final got = [for (final c in changes) (note: d.noteOf(c), sentence: d.describe(c))];
    for (final (i, g) in got.indexed) {
      expect('${g.note}\t${g.sentence}', '${want[i]['note']}\t${want[i]['sentence']}', reason: 'change $i');
    }
    expect(got, hasLength(want.length));
  });
}
