import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native sockets send WebSocket pings so half-open connections (Wi-Fi
/// hand-over, NAT timeout, laptop sleep) are detected within seconds instead
/// of hanging until the OS gives up.
WebSocketChannel connectWebSocket(Uri uri) => IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 10),
      connectTimeout: const Duration(seconds: 10),
    );
