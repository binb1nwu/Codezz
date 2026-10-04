import 'dart:async';
import 'dart:typed_data';

import 'serialization.dart';

/// Request / response codes from `packages/rpc/src/channels.shared.ts`.
abstract final class RpcRequestType {
  static const promise = 100;
  static const promiseCancel = 101;
  static const eventListen = 102;
  static const eventDispose = 103;
}

abstract final class RpcResponseType {
  static const initialize = 200;
  static const promiseSuccess = 201;
  static const promiseError = 202;
  static const promiseErrorObj = 203;
  static const eventFire = 204;
}

/// An error returned by a remote service (`ResponseType.PromiseError`).
class RpcError implements Exception {
  RpcError(this.message, {this.name, this.code, this.data});

  factory RpcError.fromWire(Object? data) {
    if (data is Map) {
      return RpcError(
        '${data['message'] ?? 'RPC error'}',
        name: data['name'] as String?,
        code: data['code']?.toString(),
        data: data['data'],
      );
    }
    return RpcError('$data', data: data);
  }

  final String message;
  final String? name;
  final String? code;
  final Object? data;

  @override
  String toString() => code == null ? message : '$message ($code)';
}

/// Raised for every pending request when the underlying connection closes.
class ConnectionClosedError implements Exception {
  const ConnectionClosedError([this.reason = 'connection closed']);
  final String reason;
  @override
  String toString() => reason;
}

/// Port of ZCode's `ChannelClient` (`packages/rpc/src/channelClient.ts`).
///
/// Services are exposed through `ProxyChannel.fromService`, so a method call
/// passes its arguments as a list (`call('zcode-agent', 'x', [params])`) and
/// an `onDynamicXxx` event passes a single raw argument.
class ChannelClient {
  ChannelClient(this._send);

  final void Function(Uint8List body) _send;

  int _lastRequestId = 0;
  bool _disposed = false;
  final Completer<void> _initialized = Completer<void>();
  final Map<int, void Function(int type, Object? data)> _handlers = {};
  final Map<int, void Function(Object error)> _pendingRejections = {};

  bool get isDisposed => _disposed;
  Future<void> get initialized => _initialized.future;

  void acceptMessage(Uint8List message) {
    if (_disposed) return;
    final reader = RpcReader(message);
    final header = reader.read();
    if (header is! List || header.isEmpty) return;
    final type = header[0];
    if (type == RpcResponseType.initialize) {
      if (!_initialized.isCompleted) _initialized.complete();
      return;
    }
    if (header.length < 2 || header[1] is! int) return;
    final body = reader.read();
    _handlers[header[1] as int]?.call(type as int, body);
  }

  Future<T> call<T>(
    String channel,
    String command, [
    List<Object?> args = const [],
    Duration? timeout,
  ]) {
    if (_disposed) {
      return Future.error(const ConnectionClosedError());
    }
    final id = _lastRequestId++;
    final completer = Completer<T>();
    Timer? timer;

    void finish() {
      timer?.cancel();
      _handlers.remove(id);
      _pendingRejections.remove(id);
    }

    _pendingRejections[id] = (error) {
      finish();
      if (!completer.isCompleted) completer.completeError(error);
    };
    _handlers[id] = (type, data) {
      switch (type) {
        case RpcResponseType.promiseSuccess:
          finish();
          if (!completer.isCompleted) completer.complete(data as T);
        case RpcResponseType.promiseError:
          finish();
          if (!completer.isCompleted) {
            completer.completeError(RpcError.fromWire(data));
          }
        case RpcResponseType.promiseErrorObj:
          finish();
          if (!completer.isCompleted) {
            completer.completeError(RpcError('$data', data: data));
          }
      }
    };

    void send() {
      if (_disposed || !_pendingRejections.containsKey(id)) return;
      _sendRequest(RpcRequestType.promise, id, channel, command, args);
    }

    if (_initialized.isCompleted) {
      send();
    } else {
      _initialized.future.then((_) => send(), onError: (_) {});
    }
    if (timeout != null) {
      timer = Timer(timeout, () {
        if (completer.isCompleted) return;
        finish();
        _sendCancel(RpcRequestType.promiseCancel, id);
        completer.completeError(
            TimeoutException('$channel.$command timed out', timeout));
      });
    }
    return completer.future;
  }

  /// Subscribes to a remote event. The listen request is sent on first
  /// subscription and disposed when the stream subscription is cancelled.
  Stream<Object?> listen(String channel, String event, [Object? arg]) {
    late final StreamController<Object?> controller;
    int? id;
    controller = StreamController<Object?>(
      onListen: () {
        if (_disposed) {
          controller.close();
          return;
        }
        final requestId = _lastRequestId++;
        id = requestId;
        _handlers[requestId] = (type, data) {
          if (type == RpcResponseType.eventFire) controller.add(data);
        };
        void send() {
          if (_disposed || !_handlers.containsKey(requestId)) return;
          _sendRequest(RpcRequestType.eventListen, requestId, channel, event, arg);
        }

        if (_initialized.isCompleted) {
          send();
        } else {
          _initialized.future.then((_) => send(), onError: (_) {});
        }
      },
      onCancel: () {
        final requestId = id;
        if (requestId == null) return;
        _handlers.remove(requestId);
        if (!_disposed) _sendCancel(RpcRequestType.eventDispose, requestId);
      },
    );
    return controller.stream;
  }

  void _sendRequest(
      int type, int id, String channel, String name, Object? arg) {
    final writer = RpcWriter()
      ..write([type, id, channel, name])
      ..write(arg);
    _send(writer.takeBytes());
  }

  void _sendCancel(int type, int id) {
    final writer = RpcWriter()
      ..write([type, id])
      ..write(null);
    try {
      _send(writer.takeBytes());
    } catch (_) {}
  }

  /// Fails every pending request; event streams simply stop firing.
  void dispose([Object reason = const ConnectionClosedError()]) {
    if (_disposed) return;
    _disposed = true;
    for (final reject in List.of(_pendingRejections.values)) {
      reject(reason);
    }
    _pendingRejections.clear();
    _handlers.clear();
    if (!_initialized.isCompleted) _initialized.completeError(reason);
    _initialized.future.ignore();
  }
}
