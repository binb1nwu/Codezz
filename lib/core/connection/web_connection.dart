import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../rpc/channel_client.dart';
import '../rpc/socket_protocol.dart';
import '../zcode/server_info.dart';
import 'device_connection.dart';
import 'ws_connect.dart';

/// Direct WebSocket RPC connection to a `zcode --web` server.
class WebDeviceConnection extends DeviceConnection {
  WebDeviceConnection(super.link, {super.log}) : super.base();

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  ChannelClient? _pending;

  @override
  Future<ChannelClient> openClient(int generation) async {
    serverInfo = await _fetchServerInfo();
    logLine('connect ${link.displayHost}');
    final socket = connectWebSocket(link.webSocketUri);
    final reader = SocketFrameReader();
    final client = _pending = ChannelClient((body) {
      try {
        socket.sink.add(SocketFrame.encode(body));
      } catch (_) {}
    });
    // Listen before `ready` resolves: the server sends `Initialize` right
    // after the upgrade and it must not be dropped.
    _socketSub = socket.stream.listen(
      (data) {
        final bytes = data is Uint8List
            ? data
            : data is List<int>
                ? Uint8List.fromList(data)
                : null;
        if (bytes == null) return;
        for (final message in reader.accept(bytes)) {
          client.acceptMessage(message);
        }
      },
      onError: (Object e) => lost(generation, '$e'),
      onDone: () => lost(
          generation, socket.closeReason ?? 'closed (${socket.closeCode})'),
      cancelOnError: true,
    );
    _socket = socket;
    await socket.ready.timeout(const Duration(seconds: 12));
    await client.initialized.timeout(const Duration(seconds: 12));
    _pending = null;
    return client;
  }

  Future<ServerInfo?> _fetchServerInfo() async {
    try {
      final res = await http
          .get(link.serverInfoUri)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 401) {
        throw const UnauthorizedError('token rejected');
      }
      if (res.statusCode != 200) {
        throw HttpStatusError(res.statusCode);
      }
      return ServerInfo.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } on UnauthorizedError {
      rethrow;
    } on HttpStatusError {
      rethrow;
    } catch (e) {
      // Browsers block this cross-origin request (the server sends no CORS
      // headers) while still allowing the WebSocket. Keep going there.
      if (kIsWeb) return serverInfo;
      rethrow;
    }
  }

  @override
  void closeTransport(String reason) {
    _pending?.dispose(ConnectionClosedError(reason));
    _pending = null;
    _socketSub?.cancel();
    _socketSub = null;
    try {
      _socket?.sink.close();
    } catch (_) {}
    _socket = null;
  }
}
