/// Hybrid logical clocks, the same format chit-server and chitd use:
/// `<unix ms, 13 digits>-<counter, 4 hex>-<device id>`, so plain string
/// comparison orders them. See docs/design.md in the chit repo.
library;

final _format = RegExp(r'^(\d{13})-([0-9a-f]{4})-([a-z0-9]{1,16})$');

/// Whether [s] is a well-formed timestamp.
bool isValidHlc(String s) => _format.hasMatch(s);

/// The parts of a timestamp, or null when it is malformed.
({int ms, int counter, String device})? parseHlc(String s) {
  final m = _format.firstMatch(s);
  if (m == null) return null;
  return (ms: int.parse(m[1]!), counter: int.parse(m[2]!, radix: 16), device: m[3]!);
}

/// Issues increasing timestamps for one device.
final class HlcClock {
  HlcClock(this.device, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final String device;
  final DateTime Function() _now;
  int _ms = 0;
  int _counter = 0;

  /// A timestamp greater than every one this clock has issued or observed.
  String now() {
    final ms = _now().millisecondsSinceEpoch;
    if (ms > _ms) {
      _ms = ms;
      _counter = 0;
    } else if (++_counter > 0xffff) {
      _ms++;
      _counter = 0;
    }
    return '${_ms.toString().padLeft(13, '0')}-${_counter.toRadixString(16).padLeft(4, '0')}-$device';
  }

  /// Moves past a timestamp seen from another device, so the next write here
  /// sorts after it even when this device's wall clock is behind.
  void observe(String hlc) {
    final p = parseHlc(hlc);
    if (p == null) return;
    if (p.ms > _ms || (p.ms == _ms && p.counter > _counter)) {
      _ms = p.ms;
      _counter = p.counter;
    }
  }
}
