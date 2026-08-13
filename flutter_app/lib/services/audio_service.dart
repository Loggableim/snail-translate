import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/session.dart';
import '../models/chat_message.dart';
import '../models/sticker_message.dart';
import 'chat_service.dart';
import 'error_logger.dart';

/// Manages WebSocket connection to relay and audio streaming.
/// Chat/messaging concerns are delegated to [ChatService].
class AudioService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  bool _isPeerConnected = false;
  bool _isMuted = false;
  bool _isReconnecting = false;
  bool _isAuthenticated = false;
  final ChatService chat = ChatService();
  final List<Map<String, dynamic>> _signals = [];
  void Function(Uint8List bytes, int sampleRate)? onPcmAudio;
  VoidCallback? onPcmAudioEnd;
  void Function(Uint8List bytes, int sampleRate)? onFishTtsAudio;
  VoidCallback? onFishTtsAudioEnd;
  void Function(Uint8List bytes, int sampleRate)? onFallbackPcmAudio;
  void Function(String signalType, dynamic signal)? onSignal;
  VoidCallback? onAuthenticated;
  void Function(Map<String, dynamic> message)? onP2pChatSend;
  void Function(Map<String, dynamic> message)? onP2pStickerSend;
  bool Function()? isP2pConnected;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Session? _session;
  Map<String, dynamic>? _fishTtsConfig;

  static const _reconnectDelays = [1, 2, 4, 8, 15, 30]; // seconds

  bool get isConnected => _isConnected;
  bool get isPeerConnected => _isPeerConnected;
  bool get isMuted => _isMuted;
  bool get isReconnecting => _isReconnecting;
  bool get isAuthenticated => _isAuthenticated;
  List<ChatMessage> get messages => chat.messages;
  List<StickerMessage> get stickers => chat.stickers;
  int get pendingCount => chat.pendingCount;
  List<Map<String, dynamic>> get signals => List.unmodifiable(_signals);

  // ── Delegated chat methods ─────────────────────────────────────────

  List<ChatMessage> searchMessages(String query) => chat.searchMessages(query);

  void deleteMessage(String messageId) => chat.deleteMessage(messageId);

  void editMessage(String messageId, String newText) =>
      chat.editMessage(messageId, newText);

  void sendChat(String text,
      {String sourceLang = 'de', String targetLang = 'en'}) {
    chat.sendChat(text, sourceLang: sourceLang, targetLang: targetLang);
  }

  void sendSticker(StickerMessage sticker) => chat.sendSticker(sticker);

  void receiveP2pData(Map<String, dynamic> message) =>
      chat.receiveP2pData(message);

  // ── Connection ─────────────────────────────────────────────────────

  Future<bool> connect(Session session) async {
    _session = session;
    await chat.init(session.inviteeId ?? session.roomId, session.roomId);
    _wireChatService();
    return _doConnect();
  }

  void _wireChatService() {
    chat.onSend = (jsonMessage) {
      if (_isConnected && _isAuthenticated) {
        _channel?.sink.add(jsonMessage);
      }
    };
    chat.onP2pSend = (message) {
      if (isP2pConnected?.call() == true) onP2pChatSend?.call(message);
    };
    chat.isP2pConnected = isP2pConnected;
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
      _tryReconnect();
      return false;
    }
  }

  void _onMessage(dynamic data) {
    try {
      if (data is List<int>) {
        final frame = Uint8List.fromList(data);
        if (frame.length < 4) return;
        final sampleRate =
            ByteData.sublistView(frame, 0, 4).getUint32(0, Endian.little);
        if (sampleRate == 0) {
          onFishTtsAudioEnd?.call();
        } else if (frame.length > 4) {
          onFishTtsAudio?.call(Uint8List.sublistView(frame, 4), sampleRate);
        }
        return;
      }
      final msg = jsonDecode(data as String);
      switch (msg['type']) {
        case 'auth_ok':
          _isAuthenticated = true;
          _sendFishTtsConfig();
          onAuthenticated?.call();
          chat.flushOutbox();
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
          chat.flushOutbox();
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
          chat.addIncomingChat(Map<String, dynamic>.from(msg));
          chat.persistConversation();
          notifyListeners();
          break;
        case 'delivery_ack':
          final messageId = msg['messageId'] as String?;
          if (messageId != null) {
            chat.handleDeliveryAck(messageId);
          }
          break;
        case 'chat_history':
          final history =
              (msg['history'] as List<dynamic>? ?? const <dynamic>[])
                  .whereType<Map<String, dynamic>>()
                  .toList();
          chat.replaceHistory(history);
          break;
        case 'sticker':
          chat.addIncomingSticker(Map<String, dynamic>.from(msg));
          chat.persistConversation();
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
        case 'pcm_end':
          onPcmAudioEnd?.call();
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
    chat.persistConversation();
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
      if (_isConnected) return;
      await _doConnect();
    });
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    notifyListeners();
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
    if (!_isConnected || _isMuted || pcm16.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'pcm_audio',
      'audio': pcm16.toList(growable: false),
      'sampleRate': sampleRate
    }));
  }

  void sendPcmAudioEnd() {
    if (!_isConnected || _isMuted) return;
    _channel?.sink.add(jsonEncode({'type': 'pcm_end'}));
  }

  void configureFishTts({
    required String voiceId,
    String model = 's2-pro',
    double temperature = 0.7,
    double topP = 0.7,
    double speed = 1.0,
  }) {
    _fishTtsConfig = {
      'type': 'fish_tts_config',
      'voiceId': voiceId,
      'model': model,
      'temperature': temperature,
      'topP': topP,
      'speed': speed,
    };
    _sendFishTtsConfig();
  }

  void _sendFishTtsConfig() {
    if (!_isConnected || !_isAuthenticated || _fishTtsConfig == null) return;
    _channel?.sink.add(jsonEncode(_fishTtsConfig));
  }

  void sendFishTtsText(String text) {
    if (!_isConnected || !_isAuthenticated || text.trim().isEmpty) return;
    _channel?.sink.add(jsonEncode({'type': 'fish_tts_text', 'text': text}));
  }

  void flushFishTts() {
    if (!_isConnected || !_isAuthenticated) return;
    _channel?.sink.add(jsonEncode({'type': 'fish_tts_flush'}));
  }

  void sendFallbackPcmAudio(Uint8List pcm16, {int sampleRate = 16000}) {
    if (!_isConnected || _isMuted || pcm16.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'fallback_pcm_audio',
      'audio': pcm16.toList(growable: false),
      'sampleRate': sampleRate,
    }));
  }

  void sendSignal(String signalType, dynamic signal) {
    if (!_isConnected || !_isAuthenticated) return;
    _channel?.sink.add(jsonEncode({
      'type': 'signal',
      'signalType': signalType,
      'signal': signal,
    }));
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _isAuthenticated = false;
    _isPeerConnected = false;
    _isReconnecting = false;
    _fishTtsConfig = null;
    notifyListeners();
  }
}
