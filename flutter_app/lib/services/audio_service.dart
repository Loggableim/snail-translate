import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/session.dart';
import '../models/chat_message.dart';
import '../models/message_status.dart';
import '../models/sticker_message.dart';
import 'error_logger.dart';

/// Manages WebSocket connection to relay and audio streaming.
/// Includes graceful reconnect with exponential backoff.
class AudioService extends ChangeNotifier {
  static const _uuid = Uuid();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  bool _isPeerConnected = false;
  bool _isMuted = false;
  bool _isReconnecting = false;
  bool _isAuthenticated = false;
  final List<ChatMessage> _messages = [];
  final List<StickerMessage> _stickers = [];
  final List<Map<String, dynamic>> _signals = [];
  final List<Map<String, dynamic>> _outbox = [];
  static const _secureStorage = FlutterSecureStorage();
  void Function(Uint8List bytes, int sampleRate)? onPcmAudio;
  void Function(Uint8List bytes, int sampleRate)? onFallbackPcmAudio;
  void Function(String signalType, dynamic signal)? onSignal;
  VoidCallback? onAuthenticated;
  void Function(Map<String, dynamic> message)? onP2pChatSend;
  void Function(Map<String, dynamic> message)? onP2pStickerSend;
  bool Function()? isP2pConnected;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Session? _session;

  static const _reconnectDelays = [1, 2, 4, 8, 15, 30]; // seconds

  bool get isConnected => _isConnected;
  bool get isPeerConnected => _isPeerConnected;
  bool get isMuted => _isMuted;
  bool get isReconnecting => _isReconnecting;
  bool get isAuthenticated => _isAuthenticated;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<StickerMessage> get stickers => List.unmodifiable(_stickers);
  int get pendingCount => _outbox.length;
  List<Map<String, dynamic>> get signals => List.unmodifiable(_signals);

  /// Search chat messages by text (case-insensitive substring match).
  List<ChatMessage> searchMessages(String query) {
    if (query.trim().isEmpty) return List.unmodifiable(_messages);
    final lower = query.toLowerCase().trim();
    return _messages
        .where((m) => m.text.toLowerCase().contains(lower))
        .toList();
  }

  Future<bool> connect(Session session) async {
    _session = session;
    await _loadConversation(session.inviteeId ?? session.roomId);
    await _loadOutbox(session.roomId);
    return _doConnect();
  }

  Future<void> _loadConversation(String conversationId) async {
    _messages.clear();
    _stickers.clear();
    final raw =
        await _secureStorage.read(key: 'snail_conversation_$conversationId');
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _messages.addAll((decoded['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((item) => ChatMessage.fromJson(item, 'local')));
      _stickers.addAll((decoded['stickers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(StickerMessage.fromJson));
    } catch (_) {
      await _secureStorage.delete(key: 'snail_conversation_$conversationId');
    }
  }

  Future<void> _persistConversation() async {
    final conversationId = _session?.inviteeId ?? _session?.roomId;
    if (conversationId == null) return;
    await _secureStorage.write(
      key: 'snail_conversation_$conversationId',
      value: jsonEncode({
        'messages': _messages
            .skip(_messages.length > 500 ? _messages.length - 500 : 0)
            .map((message) => message.toJson())
            .toList(),
        'stickers': _stickers
            .skip(_stickers.length > 500 ? _stickers.length - 500 : 0)
            .map((sticker) => sticker.toJson())
            .toList(),
      }),
    );
  }

  Future<void> _loadOutbox(String roomId) async {
    final rawValue = await _secureStorage.read(key: 'snail_outbox_$roomId');
    _outbox.clear();
    if (rawValue == null) return;
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is List<dynamic>) {
        _outbox.addAll(decoded.whereType<Map<String, dynamic>>());
      }
    } catch (_) {
      await _secureStorage.delete(key: 'snail_outbox_$roomId');
    }
  }

  Future<void> _persistOutbox() async {
    final roomId = _session?.roomId;
    if (roomId == null) return;
    await _secureStorage.write(
      key: 'snail_outbox_$roomId',
      value: jsonEncode(_outbox),
    );
  }

  Future<void> _queue(Map<String, dynamic> message) async {
    if (_outbox.length >= 200) _outbox.removeAt(0);
    _outbox.add(message);
    await _persistOutbox();
    notifyListeners();
  }

  Future<void> _flushOutbox() async {
    if (!_isAuthenticated || !_isPeerConnected || _channel == null) return;
    for (final message in List<Map<String, dynamic>>.from(_outbox)) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  bool _hasMessage(String id) =>
      id.isNotEmpty && _messages.any((item) => item.id == id);
  bool _hasSticker(String id) =>
      id.isNotEmpty && _stickers.any((item) => item.id == id);

  void _addIncomingChat(Map<String, dynamic> value) {
    final message = ChatMessage.fromJson(value, '');
    if (message.id.isEmpty || _hasMessage(message.id)) return;
    _messages.add(message);
  }

  void _addIncomingSticker(Map<String, dynamic> value) {
    final sticker = StickerMessage.fromJson(value);
    if (sticker.id.isEmpty || _hasSticker(sticker.id)) return;
    _stickers.add(sticker);
  }

  void _updateMessageStatus(String messageId, MessageStatus status) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    _messages[index] = _messages[index].copyWith(status: status);
    notifyListeners();
  }

  Future<bool> _doConnect() async {
    if (_session == null) return false;
    try {
      final uri = Uri.parse(_session!.relayUrl);
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      _isConnected = true;
      _isAuthenticated = false;
      _isReconnecting = false;
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      _channel!.sink.add(jsonEncode({
        'type': 'auth',
        'token': _session!.sessionToken,
      }));

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      notifyListeners();
      return true;
    } catch (e, st) {
      ErrorLogger.I.log(
        provider: 'websocket',
        context: 'ws.connect',
        error: e,
        stackTrace: st,
      );
      _isConnected = false;
      _isAuthenticated = false;
      _isPeerConnected = false;
      notifyListeners();
      // DNS and mobile-network handovers commonly fail before a WebSocket is
      // established. Previously only an already-open socket retried, so the
      // guest remained offline until the user left and rejoined manually.
      _tryReconnect();
      return false;
    }
  }

  void _onMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String);
      switch (msg['type']) {
        case 'auth_ok':
          _isAuthenticated = true;
          onAuthenticated?.call();
          _flushOutbox();
          notifyListeners();
          break;
        case 'auth_error':
          ErrorLogger.I.log(
            provider: 'websocket',
            context: 'ws.auth',
            error: msg['error'] ?? 'Unknown auth error',
          );
          break;
        case 'peer_joined':
          _isPeerConnected = true;
          _flushOutbox();
          notifyListeners();
          break;
        case 'peer_left':
          _isPeerConnected = false;
          notifyListeners();
          break;
        case 'session_end':
          _isConnected = false;
          _isPeerConnected = false;
          notifyListeners();
          break;
        case 'chat':
          _addIncomingChat(Map<String, dynamic>.from(msg));
          _persistConversation();
          notifyListeners();
          break;
        case 'delivery_ack':
          final messageId = msg['messageId'] as String?;
          if (messageId != null) {
            _outbox.removeWhere((item) => item['messageId'] == messageId);
            _updateMessageStatus(messageId, MessageStatus.delivered);
            _persistOutbox();
          }
          break;
        case 'chat_history':
          final history =
              (msg['history'] as List<dynamic>? ?? const <dynamic>[]);
          final outgoingMessageIds = _messages
              .where((item) => item.outgoing)
              .map((item) => item.id)
              .toSet();
          final outgoingStickerIds = _stickers
              .where((item) => item.outgoing)
              .map((item) => item.id)
              .toSet();
          _messages.clear();
          _stickers.clear();
          for (final item in history.whereType<Map<String, dynamic>>()) {
            if (item['type'] == 'sticker') {
              final value = Map<String, dynamic>.from(item);
              if (outgoingStickerIds.contains(value['messageId'])) {
                value['outgoing'] = true;
              }
              _addIncomingSticker(value);
            } else if (item['type'] == 'chat') {
              final value = Map<String, dynamic>.from(item);
              if (outgoingMessageIds.contains(value['messageId'])) {
                value['senderId'] = '';
              }
              _addIncomingChat(value);
            }
          }
          _persistConversation();
          notifyListeners();
          break;
        case 'sticker':
          _addIncomingSticker(Map<String, dynamic>.from(msg));
          _persistConversation();
          notifyListeners();
          break;
        case 'signal':
          _signals
              .add({'signalType': msg['signalType'], 'signal': msg['signal']});
          onSignal?.call(msg['signalType'] as String, msg['signal']);
          notifyListeners();
          break;
        case 'pcm_audio':
          final values =
              (msg['audio'] as List<dynamic>? ?? const []).cast<int>();
          onPcmAudio?.call(
              Uint8List.fromList(values), msg['sampleRate'] as int? ?? 24000);
          break;
        case 'fallback_pcm_audio':
          final values =
              (msg['audio'] as List<dynamic>? ?? const []).cast<int>();
          onFallbackPcmAudio?.call(
              Uint8List.fromList(values), msg['sampleRate'] as int? ?? 16000);
          break;
        case 'error':
          ErrorLogger.I.log(
            provider: 'websocket',
            context: 'ws.message',
            error: msg['error'] ?? 'Unknown error',
          );
          break;
      }
    } catch (e) {
      debugPrint('[Snail] ws.onMessage decode error: $e');
    }
  }

  void _onError(dynamic error, [StackTrace? st]) {
    ErrorLogger.I.log(
      provider: 'websocket',
      context: 'ws.error',
      error: error,
      stackTrace: st,
    );
    _isConnected = false;
    _isAuthenticated = false;
    notifyListeners();
    _persistConversation();
    _tryReconnect();
  }

  void _onDone() {
    _isConnected = false;
    _isAuthenticated = false;
    _isPeerConnected = false;
    notifyListeners();
    _tryReconnect();
  }

  void _tryReconnect() {
    // A WebSocket commonly reports both onError and onDone for one failure.
    // Schedule exactly one retry; concurrent reconnects otherwise replace the
    // authenticated socket and make an active room appear to stall.
    if (_isConnected || _reconnectTimer != null) return;
    if (_reconnectAttempt >= _reconnectDelays.length) {
      _isReconnecting = false;
      notifyListeners();
      return;
    }
    _isReconnecting = true;
    notifyListeners();

    final delay = _reconnectDelays[_reconnectAttempt];
    _reconnectAttempt++;
    debugPrint(
        '[Snail] Reconnecting in ${delay}s (attempt $_reconnectAttempt)...');

    _reconnectTimer = Timer(Duration(seconds: delay), () async {
      _reconnectTimer = null;
      if (_isConnected) return; // Already reconnected
      await _doConnect();
    });
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    notifyListeners();
  }

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
    final canSend = _isConnected && _isAuthenticated;
    _messages.add(ChatMessage(
      id: messageId,
      text: text.trim(),
      senderId: 'local',
      sourceLang: sourceLang,
      targetLang: targetLang,
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(message['timestamp']! as int),
      outgoing: true,
      status: canSend ? MessageStatus.sent : MessageStatus.queued,
    ));
    notifyListeners();
    if (isP2pConnected?.call() == true) onP2pChatSend?.call(message);
    // P2P is the low-latency delivery route; the relay still receives the
    // idempotent copy so it can provide offline history and re-delivery.
    if (!canSend) {
      _queue(message);
    } else {
      _channel?.sink.add(jsonEncode(message));
    }
  }

  void receiveP2pData(Map<String, dynamic> message) {
    if (message['type'] == 'chat') {
      _addIncomingChat(message);
      _persistConversation();
      notifyListeners();
    } else if (message['type'] == 'sticker') {
      _addIncomingSticker(message);
      _persistConversation();
      notifyListeners();
    }
  }

  void sendAudio(Uint8List pcm16) {
    if (!_isConnected || _isMuted || pcm16.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'audio',
      'audio': pcm16.toList(growable: false),
      'timestamp': DateTime.now().millisecondsSinceEpoch
    }));
  }

  void sendPcmAudio(Uint8List pcm16, {int sampleRate = 24000}) {
    if (!_isConnected || pcm16.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'pcm_audio',
      'audio': pcm16.toList(growable: false),
      'sampleRate': sampleRate
    }));
  }

  /// Sends untranslated microphone PCM to the peer which owns the fallback
  /// provider. This is only used when the sending endpoint has no live BYOK.
  void sendFallbackPcmAudio(Uint8List pcm16, {int sampleRate = 16000}) {
    if (!_isConnected || _isMuted || pcm16.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'fallback_pcm_audio',
      'audio': pcm16.toList(growable: false),
      'sampleRate': sampleRate,
    }));
  }

  void sendSticker(StickerMessage sticker) {
    final message = {
      'type': 'sticker',
      ...sticker.toJson(),
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };
    _stickers.add(sticker);
    notifyListeners();
    _persistConversation();
    if (isP2pConnected?.call() == true) onP2pStickerSend?.call(message);
    if (!_isConnected || !_isAuthenticated) {
      _queue(message);
    } else {
      _channel?.sink.add(jsonEncode(message));
    }
  }

  /// Relay only: the payload is an SDP offer/answer or ICE candidate.
  /// Media must be sent over the negotiated WebRTC connection, not this relay.
  void sendSignal(String signalType, dynamic signal) {
    if (!_isConnected) return;
    if (signalType != 'offer' &&
        signalType != 'answer' &&
        signalType != 'ice') {
      return;
    }
    _channel?.sink.add(jsonEncode(
        {'type': 'signal', 'signalType': signalType, 'signal': signal}));
  }

  void disconnect() {
    _reconnectAttempt = _reconnectDelays.length; // Prevent reconnect
    _isReconnecting = false;
    _subscription?.cancel();
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode({'type': 'end'}));
        _channel!.sink.close();
      } catch (e) {
        debugPrint('[Snail] ws.sink close error: $e');
      }
    }
    _channel = null;
    _session = null;
    _isConnected = false;
    _isAuthenticated = false;
    _isPeerConnected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    disconnect();
    super.dispose();
  }
}
