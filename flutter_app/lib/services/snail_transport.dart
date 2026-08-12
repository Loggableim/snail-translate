import 'dart:async';

/// Abstract transport layer for Snail.
///
/// Separates transport concerns (WebSocket, P2P) from domain logic.
/// Implementations handle the actual network I/O.
abstract class SnailTransport {
  /// Whether the transport is currently connected.
  bool get isConnected;

  /// Send a JSON-serializable message.
  void send(Map<String, dynamic> message);

  /// Stream of incoming messages.
  Stream<Map<String, dynamic>> get messages;

  /// Connect to the given URL.
  Future<void> connect(String url, {Map<String, String>? headers});

  /// Disconnect and clean up.
  void disconnect();
}
