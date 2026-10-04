import 'dart:math';

final Random _random = Random.secure();

String _hex(int value, int width) => value.toRadixString(16).padLeft(width, '0');

/// RFC 9562 UUID v7 (time ordered), used for V4 `commandId`s exactly like
/// ZCode's `uuidv7()`.
String uuidv7([DateTime? now]) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final timeHigh = (ms ~/ 0x10000) & 0xFFFFFFFF;
  final timeLow = ms & 0xFFFF;
  final verRandA = 0x7000 | _random.nextInt(1 << 12);
  final varRandB = 0x8000 | _random.nextInt(1 << 14);
  // 16-bit chunks: `1 << 32` is not representable on the web.
  final node = List.generate(3, (_) => _hex(_random.nextInt(1 << 16), 4)).join();
  return '${_hex(timeHigh, 8)}-${_hex(timeLow, 4)}-${_hex(verRandA, 4)}-'
      '${_hex(varRandB, 4)}-$node';
}

/// Random v4 UUID for local identifiers.
String uuidv4() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = b.map((x) => _hex(x, 2)).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
