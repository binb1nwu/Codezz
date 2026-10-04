import 'package:flutter/foundation.dart';

/// Small in-memory ring buffer of connection/protocol events, shown on the
/// diagnostics page.
class LogStore extends ChangeNotifier {
  LogStore({this.capacity = 500});

  final int capacity;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String line) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _lines.add('${two(now.hour)}:${two(now.minute)}:${two(now.second)} $line');
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
    if (kDebugMode) debugPrint(line);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}
