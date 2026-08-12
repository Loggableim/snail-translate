import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'snail_transport.dart';

/// WebSocket-based transport implementation.
///
/// Wraps [WebSocketChannel] and exposes a clean [SnailTransport] interface.
class WebSocketTransport implements SnailTransport {
  WebSocketChannel? _channel;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  bool _isConnected = false;

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  @override
  Future<void> connect(String url, {Map<String, String>? headers}) async {
    final uri = Uri.parse(url);
    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;
    _isConnected = true;

    _channel!.stream.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          _controller.add(msg);
        } catch (_) {
          // Ignore malformed messages
        }
      },
      onError: (error) {
        _isConnected = false;
        _controller.addError(error);
      },
      onDone: () {
        _isConnected = false;
        _controller.close();
      },
      cancelOnError: false,
    );
  }

  @override
  void send(Map<String, dynamic> message) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode(message));
  }

  @override
  void disconnect() {
    _isConnected = false;
    _channel?.sink.close();
    _channel = null;
  }
}
