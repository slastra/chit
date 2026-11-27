/// Joins two edits of the same text made from a common starting point (a
/// three-way merge), word by word, so neither is lost.
///
/// The same algorithm as chit's internal/merge, tie for tie: a live merge
/// in the editor and the server's must agree. Both run
/// internal/merge/testdata/cases.json; keep them in step.
library;

/// Words and the runs of whitespace between them, so joining the tokens
/// gives the text back. Whitespace as Go's \s has it (ASCII only), not
/// Dart's, which takes in Unicode spaces too: the two must split alike.
final _token = RegExp(r'[ \t\n\f\r]+|[^ \t\n\f\r]+');

List<String> _tokens(String s) => [for (final m in _token.allMatches(s)) m.group(0)!];

/// Past this many cells, a changed middle is not compared token by token,
/// and the two edits of it are kept side by side.
const _maxCells = 2000000;

/// Pairs the tokens of [x] with equal tokens of [y], in order, as many as
/// possible: m[i] is the index in y that x[i] matches, or -1.
List<int> _match(List<String> x, List<String> y) {
  final m = List<int>.filled(x.length, -1);
  var p = 0;
  while (p < x.length && p < y.length && x[p] == y[p]) {
    m[p] = p;
    p++;
  }
  var sx = x.length, sy = y.length;
  while (sx > p && sy > p && x[sx - 1] == y[sy - 1]) {
    sx--;
    sy--;
    m[sx] = sy;
  }
  final n = sx - p, k = sy - p;
  if (n == 0 || k == 0 || n * k > _maxCells) return m;
  final w = k + 1;
  final dp = List<int>.filled((n + 1) * w, 0);
  for (var i = n - 1; i >= 0; i--) {
    for (var j = k - 1; j >= 0; j--) {
      if (x[p + i] == y[p + j]) {
        dp[i * w + j] = dp[(i + 1) * w + j + 1] + 1;
      } else {
        final a = dp[(i + 1) * w + j], b = dp[i * w + j + 1];
        dp[i * w + j] = a >= b ? a : b;
      }
    }
  }
  var i = 0, j = 0;
  while (i < n && j < k) {
    if (x[p + i] == y[p + j]) {
      m[p + i] = p + j;
      i++;
      j++;
    } else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return m;
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _space(String c) => c == ' ' || c == '\n' || c == '\t' || c == '\r';

/// Joins [current] (what is there now) and [mine] (an edit made from
/// [base]). A stretch only one side changed takes that side's change; where
/// both changed the same stretch differently, both are kept, current's
/// first.
String merge3(String base, String current, String mine) {
  if (current == mine || base == mine) return current;
  if (base == current) return mine;
  final b = _tokens(base), c = _tokens(current), m = _tokens(mine);
  final toC = _match(b, c), toM = _match(b, m);
  final out = StringBuffer();
  var i = 0, ci = 0, mi = 0;
  while (true) {
    var j = i;
    while (j < b.length && (toC[j] < ci || toM[j] < mi)) {
      j++;
    }
    var cj = c.length, mj = m.length;
    if (j < b.length) {
      cj = toC[j];
      mj = toM[j];
    }
    final bs = b.sublist(i, j), cs = c.sublist(ci, cj), ms = m.sublist(mi, mj);
    if (_same(cs, bs)) {
      out.writeAll(ms);
    } else if (_same(ms, bs) || _same(cs, ms)) {
      out.writeAll(cs);
    } else {
      // both changed this stretch: keep both
      out.writeAll(cs);
      if (cs.isNotEmpty && ms.isNotEmpty && !_space(cs.last[cs.last.length - 1]) && !_space(ms.first[0])) {
        out.write(' ');
      }
      out.writeAll(ms);
    }
    if (j >= b.length) break;
    out.write(b[j]);
    i = j + 1;
    ci = cj + 1;
    mi = mj + 1;
  }
  return out.toString();
}
