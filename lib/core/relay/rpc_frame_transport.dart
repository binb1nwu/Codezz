import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../v4/wire_assembler.dart' show crc32Hex;

/// Carries one workspace bridge's Channel RPC byte stream over relay
/// payloads (`rpc-frame` / `rpc-frame-ack`, the `Xf` / `Zf` schemas of the
/// remote web client).
///
/// Every logical message is one `ChannelClient` body — there is no 13-byte
/// socket framing on this path. Messages are split into base64 fragments so
/// each relay frame stays below 1 MiB, and carry a CRC32 the desktop checks
/// (frames without it are silently ignored). The desktop's replayable
/// delivery may send a message more than once, so assembled messages are
/// deduplicated by `messageSeq`.
class RpcFrameTransport {
  RpcFrameTransport({
    required this.bridgeSessionId,
    required this.send,
    this.bridgeGeneration,
    this.recoveryId,
    this.log,
  });

  static const maxMessageBytes = 64 * 1024 * 1024;
  static const maxFragments = 256;
  static const fragmentBytes = 512 * 1024;
  static const _dedupeWindow = 1024;

  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;
  final void Function(Map<String, Object?> payload) send;
  final void Function(String line)? log;

  int _seq = 0;
  int _messageSeq = 0;
  final Map<int, _Assembly> _assemblies = {};
  final Set<int> _delivered = {};
  final Queue<int> _deliveredOrder = Queue<int>();

  final StreamController<Uint8List> _messages = StreamController<Uint8List>(sync: true);

  /// Reassembled logical messages, in arrival order.
  Stream<Uint8List> get messages => _messages.stream;

  /// Time of the last frame sent or received, for keepalive decisions.
  DateTime lastActivity = DateTime.now();

  Map<String, Object?> get _identity => {
        'bridgeSessionId': bridgeSessionId,
        if (bridgeGeneration != null) 'bridgeGeneration': bridgeGeneration,
        if (recoveryId != null) 'recoveryId': recoveryId,
      };

  void sendMessage(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxMessageBytes) {
      throw StateError('rpc-frame: invalid message size ${bytes.length}');
    }
    final messageSeq = ++_messageSeq;
    final checksum = crc32Hex(bytes);
    final count = (bytes.length + fragmentBytes - 1) ~/ fragmentBytes;
    lastActivity = DateTime.now();
    for (var i = 0; i < count; i++) {
      final start = i * fragmentBytes;
      final end = start + fragmentBytes > bytes.length ? bytes.length : start + fragmentBytes;
      send({
        'zcode_type': 'rpc-frame',
        ..._identity,
        'seq': ++_seq,
        'messageSeq': messageSeq,
        'fragmentIndex': i,
        'fragmentCount': count,
        'messageBytes': bytes.length,
        'checksum': {'algorithm': 'crc32', 'value': checksum},
        'dataBase64': base64.encode(Uint8List.sublistView(bytes, start, end)),
      });
    }
  }

  /// Feeds an `rpc-frame` payload addressed to this bridge.
  void accept(Map<String, dynamic> payload) {
    if (payload['zcode_type'] != 'rpc-frame' ||
        payload['bridgeSessionId'] != bridgeSessionId) {
      return;
    }
    lastActivity = DateTime.now();
    final messageSeq = (payload['messageSeq'] as num?)?.toInt();
    final index = (payload['fragmentIndex'] as num?)?.toInt();
    final count = (payload['fragmentCount'] as num?)?.toInt();
    final size = (payload['messageBytes'] as num?)?.toInt();
    final data = payload['dataBase64'];
    final checksum = (payload['checksum'] as Map?)?['value'] as String?;
    if (messageSeq == null || index == null || count == null || size == null || data is! String) {
      return;
    }
    if (_delivered.contains(messageSeq)) {
      if (index == count - 1) _ack(messageSeq);
      return;
    }
    if (count < 1 || count > maxFragments || index < 0 || index >= count ||
        size < 1 || size > maxMessageBytes) {
      log?.call('[rpc-frame] dropped malformed message $messageSeq ($size bytes / $count fragments)');
      return;
    }
    final Uint8List chunk;
    try {
      chunk = base64.decode(data);
    } on FormatException {
      return;
    }
    var assembly = _assemblies[messageSeq];
    if (assembly != null && (assembly.count != count || assembly.size != size)) {
      assembly = null;
    }
    assembly ??= _assemblies[messageSeq] = _Assembly(count, size);
    assembly.add(index, chunk);
    if (!assembly.isComplete) return;
    _assemblies.remove(messageSeq);
    final message = assembly.build();
    if (message.length != size || (checksum != null && crc32Hex(message) != checksum)) {
      log?.call('[rpc-frame] message $messageSeq failed its checksum');
      return;
    }
    _delivered.add(messageSeq);
    _deliveredOrder.add(messageSeq);
    if (_deliveredOrder.length > _dedupeWindow) {
      _delivered.remove(_deliveredOrder.removeFirst());
    }
    _ack(messageSeq);
    if (!_messages.isClosed) _messages.add(message);
  }

  /// Acks carry the full bridge identity: the desktop drops frames whose
  /// `bridgeGeneration` / `recoveryId` differ from its own, and a bridge
  /// whose acks never arrive degrades once unacknowledged output piles up.
  void _ack(int messageSeq) => send({
        'zcode_type': 'rpc-frame-ack',
        ..._identity,
        'ackMessageSeq': messageSeq,
      });

  void dispose() {
    _assemblies.clear();
    _messages.close();
  }
}

class _Assembly {
  _Assembly(this.count, this.size) : _parts = List<Uint8List?>.filled(count, null);

  final int count;
  final int size;
  final List<Uint8List?> _parts;
  int _received = 0;

  void add(int index, Uint8List data) {
    if (_parts[index] == null) _received++;
    _parts[index] = data;
  }

  bool get isComplete => _received == count;

  Uint8List build() {
    final out = BytesBuilder(copy: false);
    for (final part in _parts) {
      out.add(part!);
    }
    return out.takeBytes();
  }
}
