import 'dart:convert';
import 'dart:typed_data';

/// Result of feeding one physical wire frame to [TopicWireAssembler].
sealed class WireEvent {
  const WireEvent(this.topic, this.subscriptionId);
  final String topic;
  final String subscriptionId;
}

/// A logical topic frame (`{topic, subscriptionId, fromSeq, toSeq, payload}`).
class WireFrame extends WireEvent {
  WireFrame(super.topic, super.subscriptionId, this.frame, this.deliveryKind);
  final Map<String, dynamic> frame;

  /// `initial` / `online` / `recovery`.
  final String deliveryKind;
}

/// The frame could not be assembled; the subscription must resync.
class WireFault extends WireEvent {
  WireFault(super.topic, super.subscriptionId, this.reason);
  final String reason;
}

class _Assembly {
  _Assembly(this.count, this.logicalBytes, this.checksum, this.deadline);
  final int count;
  final int logicalBytes;
  final String checksum;
  final DateTime deadline;
  final Map<int, Uint8List> parts = {};
}

/// Port of ZCode's `TopicWireFrameAssembler`: turns physical
/// `TopicWireFrame`s (complete or UTF-8 byte fragments with a CRC32 of the
/// whole logical frame) into logical frames, dropping stale ordinals.
class TopicWireAssembler {
  static const _timeout = Duration(seconds: 30);
  static const _maxFragments = 1024;
  static const _maxBytes = 16 * 1024 * 1024;

  final Map<String, int> _settledOrdinal = {};
  final Map<String, _Assembly> _assemblies = {};

  static String _route(String topic, String sub) => '$topic\u0000$sub';

  List<WireEvent> accept(Map<String, dynamic> wire) {
    final topic = wire['topic'];
    final sub = wire['subscriptionId'];
    if (topic is! String || sub is! String) return const [];
    final out = <WireEvent>[..._expire(DateTime.now())];
    final route = _route(topic, sub);
    final ordinal = (wire['logicalFrameOrdinal'] as num?)?.toInt() ?? 0;
    final deliveryKind = wire['deliveryKind'] as String? ?? 'online';
    final frameId = wire['logicalFrameId'] as String? ?? '';
    if (ordinal <= (_settledOrdinal[route] ?? 0)) return out;

    if (wire['kind'] == 'complete') {
      final frame = wire['frame'];
      if (frame is! Map<String, dynamic>) {
        return out..add(WireFault(topic, sub, 'proto.invalidFrame'));
      }
      _settle(route, ordinal);
      return out..add(WireFrame(topic, sub, frame, deliveryKind));
    }
    if (wire['kind'] != 'fragment') {
      return out..add(WireFault(topic, sub, 'proto.unknownWireKind'));
    }

    final index = (wire['fragmentIndex'] as num?)?.toInt();
    final count = (wire['fragmentCount'] as num?)?.toInt();
    final logicalBytes = (wire['logicalBytes'] as num?)?.toInt();
    final checksum = (wire['checksum'] as Map?)?['value'] as String?;
    final data = wire['dataBase64'];
    if (index == null ||
        count == null ||
        logicalBytes == null ||
        checksum == null ||
        data is! String ||
        count < 1 ||
        count > _maxFragments ||
        index < 0 ||
        index >= count ||
        logicalBytes > _maxBytes) {
      return out..add(WireFault(topic, sub, 'proto.invalidFragment'));
    }
    final key = '$route\u0000$frameId\u0000$ordinal';
    final assembly = _assemblies.putIfAbsent(
      key,
      () => _Assembly(count, logicalBytes, checksum, DateTime.now().add(_timeout)),
    );
    if (assembly.count != count ||
        assembly.logicalBytes != logicalBytes ||
        assembly.checksum != checksum) {
      _assemblies.remove(key);
      return out..add(WireFault(topic, sub, 'proto.fragmentMismatch'));
    }
    try {
      assembly.parts[index] = base64Decode(data);
    } on FormatException {
      _assemblies.remove(key);
      return out..add(WireFault(topic, sub, 'proto.invalidBase64'));
    }
    if (assembly.parts.length < count) return out;

    _assemblies.remove(key);
    final bytes = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      bytes.add(assembly.parts[i]!);
    }
    final logical = bytes.takeBytes();
    if (logical.length != logicalBytes || crc32Hex(logical) != checksum) {
      return out..add(WireFault(topic, sub, 'proto.checksumMismatch'));
    }
    try {
      final frame = jsonDecode(utf8.decode(logical));
      if (frame is! Map<String, dynamic>) throw const FormatException();
      _settle(route, ordinal);
      return out..add(WireFrame(topic, sub, frame, deliveryKind));
    } on FormatException {
      return out..add(WireFault(topic, sub, 'proto.invalidJson'));
    }
  }

  void _settle(String route, int ordinal) {
    _settledOrdinal[route] = ordinal;
    // Older partial assemblies of this route can never be delivered now.
    _assemblies.removeWhere((key, _) {
      if (!key.startsWith('$route\u0000')) return false;
      final ord = int.tryParse(key.substring(key.lastIndexOf('\u0000') + 1));
      return ord != null && ord <= ordinal;
    });
  }

  List<WireEvent> _expire(DateTime now) {
    if (_assemblies.isEmpty) return const [];
    final out = <WireEvent>[];
    _assemblies.removeWhere((key, assembly) {
      if (assembly.deadline.isAfter(now)) return false;
      final parts = key.split('\u0000');
      out.add(WireFault(parts[0], parts[1], 'proto.assemblyTimeout'));
      return true;
    });
    return out;
  }

  /// Forget a subscription (unsubscribed or replaced).
  void discard(String topic, String subscriptionId) {
    final route = _route(topic, subscriptionId);
    _settledOrdinal.remove(route);
    _assemblies.removeWhere((key, _) => key.startsWith('$route\u0000'));
  }

  void clear() {
    _settledOrdinal.clear();
    _assemblies.clear();
  }
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// CRC32 (IEEE) as lowercase 8-digit hex, same as `crc32WireBytes`.
String crc32Hex(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return ((crc ^ 0xFFFFFFFF) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
