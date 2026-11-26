import 'package:chit/core/labels.dart';
import 'package:chit/core/protocol.dart';
import 'package:chit/data/replica.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final labels = [
    Label({'id': 'a', 'name': 'Recipes'}),
    Label({'id': 'b', 'name': 'Home  projects'}),
  ];

  test('names: trimmed, spaced once, matched without case', () {
    expect(labelName('  Garden   ideas '), 'Garden ideas');
    expect(labelNamed(labels, 'recipes')?.id, 'a');
    expect(labelNamed(labels, ' home projects')?.id, 'b');
    expect(labelNamed(labels, 'Recipe'), isNull);
    expect(labelNamed(labels, '   '), isNull);
  });

  test('a label over a selection: all, none or some', () {
    expect(
      labelState([
        ['a'],
        ['a', 'b'],
      ], 'a'),
      isTrue,
    );
    expect(
      labelState([
        ['b'],
        [],
      ], 'a'),
      isFalse,
    );
    expect(
      labelState([
        ['a'],
        ['b'],
      ], 'a'),
      isNull,
    );
  });

  test('toggling sends only the notes that change', () {
    final notes = {
      'n1': ['a'],
      'n2': <String>[],
      'n3': ['b'],
    };
    expect(toggleLabel(notes, 'a', on: true), {
      'n2': ['a'],
      'n3': ['b', 'a'],
    });
    expect(toggleLabel(notes, 'a', on: false), {'n1': <String>[]});
  });

  test("a note's labels skip deleted and unknown ids, by name", () {
    final lib = Library(
      notes: [
        Note({'id': 'n'}),
      ],
      items: const {},
      members: const {},
      states: {
        'n': NoteState({
          'note': 'n',
          'labels': ['b', 'gone', 'a'],
        }),
      },
      attachments: const {},
      labels: labels,
    );
    expect(lib.labelsOf('n').map((l) => l.id), ['a', 'b']);
  });
}
