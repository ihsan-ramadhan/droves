import 'package:web_socket_channel/web_socket_channel.dart';

/// browsers attach same-origin cookies themselves and reject custom headers
WebSocketChannel connectBridgeSocket(Uri uri, {String? cookie}) {
  return WebSocketChannel.connect(uri);
}
