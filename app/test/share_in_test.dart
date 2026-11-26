import 'package:chit/ui/share_in.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a shared link becomes a link note; other text, a text note', () {
    expect(noteTextOf('https://www.material.io/blog/m3', ''), (
      title: 'material.io',
      body: 'https://www.material.io/blog/m3',
    ));
    expect(noteTextOf(' https://x.org/a ', 'A great read'), (title: 'A great read', body: 'https://x.org/a'));
    expect(noteTextOf('Pick up the dry cleaning', ''), (title: '', body: 'Pick up the dry cleaning'));
    expect(noteTextOf('Look at this https://x.org', 'Trip'), (title: 'Trip', body: 'Look at this https://x.org'));
  });
}
