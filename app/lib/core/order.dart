/// Fractional index keys for checklist items, the same algorithm as chit's
/// internal/order: base-62 strings in ASCII order, never ending in '0', so a
/// key between any two others always exists.
library;

const _digits = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

int _digit(String c) => _digits.indexOf(c);

bool isValidOrderKey(String k) =>
    k.isNotEmpty && !k.endsWith('0') && k.split('').every((c) => _digits.contains(c));

/// A key after [a] ("" for an empty list). Steps the first digit it can; when
/// every digit is 'z' it extends with '1', so appends stay short.
String orderAfter(String a) {
  for (var i = 0; i < a.length; i++) {
    final d = _digit(a[i]);
    if (d < _digits.length - 1) return a.substring(0, i) + _digits[d + 1];
  }
  return '$a${_digits[1]}';
}

/// A key before [b] ("" for an empty list).
String orderBefore(String b) => b.isEmpty ? orderAfter('') : orderBetween('', b);

/// A key strictly between [a] and [b]; either may be "" for the list's start
/// or end.
String orderBetween(String a, String b) {
  if (b.isNotEmpty && a.compareTo(b) >= 0) {
    throw ArgumentError('orderBetween: $a must sort before $b');
  }
  return b.isEmpty ? orderAfter(a) : _midpoint(a, b);
}

String _midpoint(String a, String b) {
  if (b.isNotEmpty) {
    var n = 0;
    while (n < b.length && (n < a.length ? a[n] : '0') == b[n]) {
      n++;
    }
    if (n > 0) return b.substring(0, n) + _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
  }
  final da = a.isEmpty ? 0 : _digit(a[0]);
  final db = b.isEmpty ? _digits.length : _digit(b[0]);
  if (db - da > 1) return _digits[(da + db + 1) ~/ 2];
  if (b.length > 1) return b.substring(0, 1);
  return _digits[da] + _midpoint(a.length > 1 ? a.substring(1) : '', '');
}
