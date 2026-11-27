import 'package:chit/core/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('links in text, each once, without the closing punctuation', () {
    final found = linksIn(
      'See https://m3.material.io/components/chips. Also (www.example.com/a) and '
      'https://en.wikipedia.org/wiki/Note_(typography), https://m3.material.io/components/chips again.',
    );
    expect(found.map((u) => u.toString()), [
      'https://m3.material.io/components/chips',
      'https://www.example.com/a',
      'https://en.wikipedia.org/wiki/Note_(typography)',
    ]);
  });

  test('no links in plain text', () {
    expect(linksIn('milk, eggs. bread'), isEmpty);
  });

  test('labels read as host and path', () {
    expect(linkLabel(Uri.parse('https://www.example.com/a/b')), 'example.com/a/b');
    expect(linkLabel(Uri.parse('https://example.com/')), 'example.com');
  });
}
