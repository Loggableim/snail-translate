import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../models/message_status.dart';

/// Manages chat messages, persistence, and outbox.
///
/// Extracted from AudioService to separate messaging concerns from
/// WebSocket/audio streaming.
class ChatService extends ChangeNotifier {
  static const _uuid = Uuid();
  static const _secureStorage = FlutterSecureStorage();

  final List<ChatMessage> _messages = [];
  final List<Map<String, dynamic>> _outbox = [];
  final Set<String> _inFlight = <String>{};

  /// Callback to send a raw JSON message through the WebSocket.
  void Function(String jsonMessage)? onSend;
  bool Function()? canSend;

  /// Callback to send via P2P (WebRTC data channel).
  void Function(Map<String, dynamic> message)? onP2pSend;

  /// Whether P2P is currently connected.
  bool Function()? isP2pConnected;

  String? _conversationId;
  String? _roomId;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  int get pendingCount => _outbox.length;

  // ── Initialization ─────────────────────────────────────────────────

  Future<void> init(String conversationId, String roomId) async {
    _conversationId = conversationId;
    _roomId = roomId;
    await _loadConversation();
    await _loadOutbox();
  }

  // ── Persistence ────────────────────────────────────────────────────

  Future<void> _loadConversation() async {
    _messages.clear();
    final raw = await _secureStorage.read(
        key: 'snail_conversation_$_conversationId');
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _messages.addAll((decoded['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((item) => ChatMessage.fromJson(item, 'local')));
    } catch (_) {
      await _secureStorage.delete(
          key: 'snail_conversation_$_conversationId');
    }
  }

  Future<void> _persistConversation() async {
    if (_conversationId == null) return;
    await _secureStorage.write(
      key: 'snail_conversation_$_conversationId',
      value: jsonEncode({
        'messages': _messages
            .skip(_messages.length > 500 ? _messages.length - 500 : 0)
            .map((message) => message.toJson())
            .toList(),
      }),
    );
  }

  Future<void> _loadOutbox() async {
    final rawValue =
        await _secureStorage.read(key: 'snail_outbox_$_roomId');
    _outbox.clear();
    if (rawValue == null) return;
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is List<dynamic>) {
        _outbox.addAll(decoded.whereType<Map<String, dynamic>>());
      }
    } catch (_) {
      await _secureStorage.delete(key: 'snail_outbox_$_roomId');
    }
  }

  Future<void> _persistOutbox() async {
    if (_roomId == null) return;
    await _secureStorage.write(
      key: 'snail_outbox_$_roomId',
      value: jsonEncode(_outbox),
    );
  }

  // ── Outbox ─────────────────────────────────────────────────────────

  Future<void> _queue(Map<String, dynamic> message) async {
    if (_outbox.length >= 200) _outbox.removeAt(0);
    _outbox.add(message);
    await _persistOutbox();
    notifyListeners();
  }

  /// Flush queued messages. Called by AudioService when connection is ready.
  void flushOutbox() {
    if (canSend?.call() == false) return;
    for (final message in List<Map<String, dynamic>>.from(_outbox)) {
      final id = message['messageId'];
      if (id is String && !_inFlight.add(id)) continue;
      onSend?.call(jsonEncode(message));
    }
  }

  /// Makes queued messages eligible for delivery after a transport drop.
  void markTransportUnavailable() => _inFlight.clear();

  // ── Idempotency ────────────────────────────────────────────────────

  bool _hasMessage(String id) =>
      id.isNotEmpty && _messages.any((item) => item.id == id);

  // ── Incoming ───────────────────────────────────────────────────────

  void addIncomingChat(Map<String, dynamic> value) {
    final message = ChatMessage.fromJson(value, '');
    if (message.id.isEmpty || _hasMessage(message.id)) return;
    _messages.add(message);
  }


  void updateMessageStatus(String messageId, MessageStatus status) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    _messages[index] = _messages[index].copyWith(status: status);
    notifyListeners();
  }

  // ── Outgoing ───────────────────────────────────────────────────────

  void sendChat(String text,
      {String sourceLang = 'de', String targetLang = 'en'}) {
    if (text.trim().isEmpty) return;
    final messageId = _uuid.v4();
    final message = {
      'type': 'chat',
      'messageId': messageId,
      'text': text.trim(),
      'sourceLang': sourceLang,
      'targetLang': targetLang,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final relayAvailable = onSend != null && (canSend?.call() ?? true);
    final p2pAvailable = isP2pConnected?.call() == true && onP2pSend != null;
    _messages.add(ChatMessage(
      id: messageId,
      text: text.trim(),
      senderId: 'local',
      sourceLang: sourceLang,
      targetLang: targetLang,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
          message['timestamp']! as int),
      outgoing: true,
      status: relayAvailable || p2pAvailable
          ? MessageStatus.sent
          : MessageStatus.queued,
    ));
    notifyListeners();
    if (p2pAvailable) onP2pSend?.call(message);
    if (!relayAvailable && !p2pAvailable) {
      _queue(message);
    } else if (relayAvailable) {
      onSend?.call(jsonEncode(message));
      _inFlight.add(messageId);
    }
  }

  void deleteMessage(String messageId) {
    final removed = _messages.where((m) => m.id == messageId).toList();
    if (removed.isEmpty) return;
    _messages.removeWhere((m) => m.id == messageId);
    _persistConversation();
    notifyListeners();
    final message = {'type': 'delete', 'messageId': messageId};
    if (isP2pConnected?.call() == true) onP2pSend?.call(message);
    onSend?.call(jsonEncode(message));
  }

  void editMessage(String messageId, String newText) {
    if (newText.trim().isEmpty) return;
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    _messages[index] = ChatMessage(
      id: _messages[index].id,
      text: newText.trim(),
      senderId: _messages[index].senderId,
      sourceLang: _messages[index].sourceLang,
      targetLang: _messages[index].targetLang,
      timestamp: _messages[index].timestamp,
      outgoing: _messages[index].outgoing,
      status: _messages[index].status,
    );
    _persistConversation();
    notifyListeners();
    final message = {
      'type': 'edit',
      'messageId': messageId,
      'text': newText.trim()
    };
    if (isP2pConnected?.call() == true) onP2pSend?.call(message);
    onSend?.call(jsonEncode(message));
  }

  // ── Search ─────────────────────────────────────────────────────────

  List<ChatMessage> searchMessages(String query) {
    if (query.trim().isEmpty) return List.unmodifiable(_messages);
    final lower = query.toLowerCase().trim();
    return _messages
        .where((m) => m.text.toLowerCase().contains(lower))
        .toList();
  }

  // ── P2P ────────────────────────────────────────────────────────────

  void receiveP2pData(Map<String, dynamic> message) {
    if (message['type'] == 'chat') {
      addIncomingChat(message);
      _persistConversation();
      notifyListeners();
    }
  }

  // ── Delivery ack ───────────────────────────────────────────────────

  void handleDeliveryAck(String messageId) {
    _inFlight.remove(messageId);
    _outbox.removeWhere((item) => item['messageId'] == messageId);
    updateMessageStatus(messageId, MessageStatus.delivered);
    _persistOutbox();
  }

  // ── Chat history ───────────────────────────────────────────────────

  void replaceHistory(List<Map<String, dynamic>> history) {
    final outgoingMessageIds = _messages
        .where((item) => item.outgoing)
        .map((item) => item.id)
        .toSet();
    _messages.clear();
    for (final item in history) {
      if (item['type'] == 'chat') {
        final value = Map<String, dynamic>.from(item);
        if (outgoingMessageIds.contains(value['messageId'])) {
          value['senderId'] = '';
        }
        addIncomingChat(value);
      }
    }
    _persistConversation();
    notifyListeners();
  }

  // ── Persist after external changes ─────────────────────────────────

  void persistConversation() => _persistConversation();
}
