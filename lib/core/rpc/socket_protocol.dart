import 'dart:typed_data';

/// Message framing used by ZCode's `SocketProtocol` over WebSocket
/// (`packages/rpc/src/protocol.ts`):
///
/// ```
/// ┌─────────┬──────────┬──────────┬──────────────┐
/// │ type(1) │  id(4)   │  ack(4)  │  length(4)   │  + body
/// └─────────┴──────────┴──────────┴──────────────┘
/// ```
///
/// Only `Regular` (1) messages carry RPC payloads; other types are ignored.
abstract final class SocketFrame {
  static const headerSize = 13;
  static const typeRegular = 1;

  static Uint8List encode(Uint8List body) {
    final out = Uint8List(headerSize + body.length);
    final view = ByteData.sublistView(out);
    view.setUint8(0, typeRegular);
    view.setUint32(1, 0);
    view.setUint32(5, 0);
    view.setUint32(9, body.length);
    out.setRange(headerSize, out.length, body);
    return out;
  }
}

/// Incremental frame reader. The server writes one frame per WebSocket
/// message, but the reader tolerates frames that are split or coalesced.
class SocketFrameReader {
  final List<Uint8List> _chunks = [];
  int _buffered = 0;

  List<Uint8List> accept(Uint8List chunk) {
    final out = <Uint8List>[];
    if (_buffered == 0) {
      // Fast path: whole frames in a single chunk, no copying.
      var offset = 0;
      while (chunk.length - offset >= SocketFrame.headerSize) {
        final view = ByteData.sublistView(chunk, offset);
        final length = view.getUint32(9);
        final total = SocketFrame.headerSize + length;
        if (chunk.length - offset < total) break;
        if (view.getUint8(0) == SocketFrame.typeRegular) {
          out.add(Uint8List.sublistView(
              chunk, offset + SocketFrame.headerSize, offset + total));
        }
        offset += total;
      }
      if (offset < chunk.length) {
        _chunks.add(Uint8List.sublistView(chunk, offset));
        _buffered = chunk.length - offset;
      }
      return out;
    }

    _chunks.add(chunk);
    _buffered += chunk.length;
    final data = Uint8List(_buffered);
    var pos = 0;
    for (final c in _chunks) {
      data.setRange(pos, pos + c.length, c);
      pos += c.length;
    }
    _chunks.clear();
    _buffered = 0;
    out.addAll(accept(data));
    return out;
  }

  void reset() {
    _chunks.clear();
    _buffered = 0;
  }
}
