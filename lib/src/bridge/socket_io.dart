import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// native WebSocket clients have no cookie jar; the cookie travels as a header
WebSocketChannel connectBridgeSocket(Uri uri, {String? cookie}) {
  return IOWebSocketChannel.connect(
    uri,
    headers: cookie == null ? null : {'cookie': cookie},
    pingInterval: const Duration(seconds: 25),
    connectTimeout: const Duration(seconds: 12),
  );
}
