import 'dart:convert';
import 'dart:typed_data';

/// Binary value codec, a port of `packages/rpc/src/serialization.ts` in ZCode.
///
/// Every RPC message is `serialize(header) + serialize(body)`. A value is a
/// one-byte type tag followed by a VQL (7-bit, little-endian) length and the
/// payload:
///
/// | tag | meaning   | payload                  |
/// |-----|-----------|--------------------------|
/// | 0   | undefined | –                        |
/// | 1   | string    | len + utf8 bytes         |
/// | 2   | Buffer    | len + bytes              |
/// | 3   | VSBuffer  | len + bytes              |
/// | 4   | array     | count + values           |
/// | 5   | object    | len + utf8 JSON          |
/// | 6   | int       | VQL value                |
abstract final class RpcTag {
  static const undefined = 0;
  static const string = 1;
  static const buffer = 2;
  static const vsBuffer = 3;
  static const array = 4;
  static const object = 5;
  static const int32 = 6;
}

/// Nested `Uint8Array`s inside JSON objects are tagged by ZCode so they survive
/// the JSON fallback (see `encodeRpcJsonValue`).
const _nestedBytesMarker = '__zcode_rpc_nested_uint8array_v1';

class RpcWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void _byte(int value) => _out.addByte(value & 0xFF);

  void _vql(int value) {
    // Mirrors writeInt32VQL: treats the value as an unsigned 32-bit integer.
    var v = value & 0xFFFFFFFF;
    if (v == 0) {
      _out.addByte(0);
      return;
    }
    while (v != 0) {
      var b = v & 0x7F;
      v >>= 7;
      if (v != 0) b |= 0x80;
      _out.addByte(b);
    }
  }

  void write(Object? value) {
    if (value == null) {
      _byte(RpcTag.undefined);
    } else if (value is String) {
      final bytes = utf8.encode(value);
      _byte(RpcTag.string);
      _vql(bytes.length);
      _out.add(bytes);
    } else if (value is Uint8List) {
      _byte(RpcTag.buffer);
      _vql(value.length);
      _out.add(value);
    } else if (value is List) {
      _byte(RpcTag.array);
      _vql(value.length);
      for (final item in value) {
        write(item);
      }
    } else if (value is int && value >= 0 && value <= 0x7FFFFFFF) {
      _byte(RpcTag.int32);
      _vql(value);
    } else {
      final bytes = utf8.encode(jsonEncode(_markNestedBytes(value)));
      _byte(RpcTag.object);
      _vql(bytes.length);
      _out.add(bytes);
    }
  }

  /// `jsonEncode` would turn a nested `Uint8List` into a number array; ZCode
  /// expects its base64 marker object instead (`encodeRpcJsonValue`).
  static Object? _markNestedBytes(Object? value) {
    if (value is Uint8List) {
      return {_nestedBytesMarker: true, 'base64': base64Encode(value)};
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry('$k', _markNestedBytes(v)));
    }
    if (value is List) return value.map(_markNestedBytes).toList();
    return value;
  }

  Uint8List takeBytes() => _out.takeBytes();
}

class RpcReader {
  RpcReader(this._data);

  final Uint8List _data;
  int _pos = 0;

  bool get hasMore => _pos < _data.length;

  Uint8List _read(int count) {
    if (_pos + count > _data.length) {
      throw const FormatException('rpc: truncated value');
    }
    final out = Uint8List.sublistView(_data, _pos, _pos + count);
    _pos += count;
    return out;
  }

  int _vql() {
    var value = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _data.length) {
        throw const FormatException('rpc: truncated varint');
      }
      final b = _data[_pos++];
      value |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return value & 0xFFFFFFFF;
      shift += 7;
      if (shift > 35) throw const FormatException('rpc: varint overflow');
    }
  }

  Object? read() {
    if (!hasMore) return null;
    final tag = _data[_pos++];
    switch (tag) {
      case RpcTag.undefined:
        return null;
      case RpcTag.string:
        return utf8.decode(_read(_vql()), allowMalformed: true);
      case RpcTag.buffer:
      case RpcTag.vsBuffer:
        return Uint8List.fromList(_read(_vql()));
      case RpcTag.array:
        final count = _vql();
        return List<Object?>.generate(count, (_) => read(), growable: false);
      case RpcTag.object:
        final text = utf8.decode(_read(_vql()), allowMalformed: true);
        final decoded = jsonDecode(text);
        return text.contains(_nestedBytesMarker)
            ? _restoreNestedBytes(decoded)
            : decoded;
      case RpcTag.int32:
        return _vql();
      default:
        throw FormatException('rpc: unknown tag $tag');
    }
  }

  static Object? _restoreNestedBytes(Object? value) {
    if (value is Map) {
      if (value.length == 2 &&
          value[_nestedBytesMarker] == true &&
          value['base64'] is String) {
        return base64Decode(value['base64'] as String);
      }
      return value.map<String, Object?>(
          (k, v) => MapEntry(k as String, _restoreNestedBytes(v)));
    }
    if (value is List) return value.map(_restoreNestedBytes).toList();
    return value;
  }
}
