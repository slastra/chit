/// Web links in a note's text: found, so they can be opened.
library;

/// http(s) links, and bare "www." ones. A link ends at whitespace, and
/// trailing punctuation that closes a sentence is left off.
final _link = RegExp(r'''(?:https?://|www\.)[^\s<>"']+''', caseSensitive: false);

/// The links in [text], in order, each once, as URIs to open.
List<Uri> linksIn(String text) {
  final seen = <String>{};
  final out = <Uri>[];
  for (final m in _link.allMatches(text)) {
    var s = m.group(0)!;
    while (s.isNotEmpty && '.,;:!?)]}'.contains(s[s.length - 1])) {
      // a ")" that closes one opened in the link stays (wiki links)
      if (s.endsWith(')') && '('.allMatches(s).length >= ')'.allMatches(s).length) break;
      s = s.substring(0, s.length - 1);
    }
    final uri = Uri.tryParse(s.toLowerCase().startsWith('www.') ? 'https://$s' : s);
    if (uri == null || uri.host.isEmpty || !seen.add(uri.toString())) continue;
    out.add(uri);
  }
  return out;
}

/// A link as a person reads it: its host without "www.", then its path.
String linkLabel(Uri uri) {
  final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
  final path = uri.path == '/' ? '' : uri.path;
  return '$host$path';
}
