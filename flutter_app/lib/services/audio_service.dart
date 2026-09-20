import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../models/session.dart';
import '../models/chat_message.dart';
import 'chat_service.dart';
import 'error_logger.dart';
import 'chat_crypto_service.dart';
import '../generated/protocol.dart';

/// Manages WebSocket connection to relay and audio streaming.
/// Chat/messaging concerns are delegated to [ChatService].
class AudioService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  bool _isPeerConnected = false;
  bool _isMuted = false;
  bool _isReconnecting = false;
  bool _reconnectExhausted = false;
  bool _isAuthenticated = false;
  bool _terminalAuthError = false;
  bool _disposed = false;
  String? _connectionError;
  final ChatService chat = ChatService();
  final List<Map<String, dynamic>> _signals = [];
  static const _maxSignals = 256;
  void Function(Uint8List bytes, int sampleRate)? onPcmAudio;
  VoidCallback? onPcmAudioEnd;
  void Function(Uint8List bytes, int sampleRate)? onFishTtsAudio;
  VoidCallback? onFishTtsAudioEnd;
  void Function(Uint8List bytes, int sampleRate)? onFallbackPcmAudio;
  void Function(String signalType, dynamic signal)? onSignal;
  VoidCallback? onAuthenticated;
  /// Guide mode: a subtitle arrived from the host.
  void Function(Map<String, dynamic> subtitle)? onSubtitle;
  /// Guide mode: the audience size changed (host side).
  void Function(int count)? onListenerCountChanged;
  /// Guide mode: the audience roster changed (host side).
  void Function(List<String> listenerIds)? onListenerListChanged;
  /// Guide mode: the host removed this listener.
  VoidCallback? onKicked;
  /// A contact request arrived from the peer.
  void Function(Map<String, dynamic> request)? onContactRequest;
  /// The peer answered our contact request.
  void Function(Map<String, dynamic> response)? onContactResponse;
  Future<String?> Function()? sessionTokenRefresher;
  String? localAgreementPublicKey;
  /// This device's Snail identity, sent as a header on the WebSocket upgrade.
  ///
  /// The worker's upgrade rate limit keys on the identity when present and on
  /// the client IP otherwise. Without it, an audience behind one NAT (a tour
  /// group on hotel wifi, everyone in the same room) shares a single bucket
  /// and the 41st listener is refused — exactly the guide-mode use case.
  String? localIdentityId;
  Future<String?> Function(String peerPublicKey)? sharedSecretDeriver;
  bool Function()? isP2pConnected;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  /// Keeps the relay socket warm.
  ///
  /// The relay answers `ping`, but nothing ever sent one, so a NAT or proxy
  /// could drop the idle connection without the app noticing until the next
  /// send failed — reconnect then started late and messages sat in the outbox.
  Timer? _keepaliveTimer;
  static const _keepaliveInterval = Duration(seconds: 25);
  Session? _session;
  Map<String, dynamic>? _fishTtsConfig;
  int _listenerCount = 0;
  final List<String> _listenerIds = <String>[];

  static const _reconnectDelays = [1, 2, 4, 8, 15, 30]; // seconds

  bool get isConnected => _isConnected;
  bool get isPeerConnected => _isPeerConnected;
  bool get isMuted => _isMuted;
  bool get isReconnecting => _isReconnecting;
  bool get isReconnectExhausted => _reconnectExhausted;
  bool get isAuthenticated => _isAuthenticated;
  bool get hasTerminalAuthError => _terminalAuthError;
  String? get connectionError => _connectionError;
  /// Current audience size in a guide room (0 in duo mode).
  int get listenerCount => _listenerCount;
  List<ChatMessage> get messages => chat.messages;
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

  Future<void> receiveP2pData(Map<String, dynamic> message) =>
      chat.receiveP2pData(message);

  // ── Connection ─────────────────────────────────────────────────────

  Future<bool> connect(Session session) async {
    _session = session;
    _terminalAuthError = false;
    _connectionError = null;
    _reconnectAttempt = 0;
    _reconnectExhausted = false;
    await chat.init(session.inviteeId ?? session.roomId, session.roomId);
    _wireChatService();
    return _doConnect();
  }

  /// Sends a periodic ping so an idle socket is not dropped silently.
  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) {
      if (!_isConnected || !_isAuthenticated) return;
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        // A closed socket reports through onDone; nothing to do here.
      }
    });
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  void _wireChatService() {
    chat.onSend = (jsonMessage) {
      // Returns whether the message actually left the device. A false answer
      // makes ChatService re-queue it: the channel can die between the
      // `canSend()` check and this call, and silently dropping the message
      // there loses it for good.
      if (!_isConnected || !_isAuthenticated) return false;
      final sink = _channel?.sink;
      if (sink == null) return false;
      try {
        sink.add(jsonMessage);
        return true;
      } catch (_) {
        // A locally closed socket throws before its stream reports onDone.
        return false;
      }
    };
    chat.canSend = () => _isConnected && _isAuthenticated;
    chat.onP2pSend = (message) {
      if (isP2pChatConnected?.call() == true) p2pChatSend?.call(message);
    };
    chat.isP2pConnected = isP2pChatConnected;
  }

  Future<bool> _doConnect() async {
    if (_session == null) return false;
    try {
      final refreshed = await sessionTokenRefresher?.call();
      if (refreshed != null && refreshed.trim().isNotEmpty) {
        _session = _session!.copyWith(sessionToken: refreshed.trim());
      }
      final uri = Uri.parse(_session!.relayUrl);
      // The identity travels as an upgrade header so the worker's rate limit
      // counts per device instead of per IP: an audience sharing one NAT must
      // not be throttled as if it were a single client.
      final identity = localIdentityId?.trim();
      _channel = (identity != null && identity.isNotEmpty)
          ? IOWebSocketChannel.connect(uri, headers: {'X-Snail-Identity': identity})
          : WebSocketChannel.connect(uri);
      await _channel!.ready;
      _isConnected = true;
      _isAuthenticated = false;
      _isReconnecting = false;
      _reconnectExhausted = false;
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      _channel!.sink.add(jsonEncode({
        'type': 'auth',
        'token': _session!.sessionToken,
        'protocolVersion': protocolVersion,
        if (localAgreementPublicKey?.isNotEmpty == true)
          'agreementPublicKey': localAgreementPublicKey,
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
        if (frame.length < 5) return;
        final sampleRate =
            ByteData.sublistView(frame, 1, 5).getUint32(0, Endian.little);
        final kind = frame[0];
        if (sampleRate == 0) {
          if (kind == 1) onFishTtsAudioEnd?.call();
          if (kind == 2) onPcmAudioEnd?.call();
        } else if (frame.length > 5) {
          final bytes = Uint8List.sublistView(frame, 5);
          if (kind == 1) onFishTtsAudio?.call(bytes, sampleRate);
          if (kind == 2) onPcmAudio?.call(bytes, sampleRate);
          if (kind == 3) onFallbackPcmAudio?.call(bytes, sampleRate);
        }
        return;
      }
      final msg = jsonDecode(data as String);
      switch (msg['type']) {
        case 'auth_ok':
          _isAuthenticated = true;
          // A (re)connecting guide host receives the current audience size so
          // its counter is correct before the next join event arrives.
          final authCount = msg['count'];
          if (authCount is int) {
            _listenerCount = authCount;
            onListenerCountChanged?.call(authCount);
          }
          _sendFishTtsConfig();
          _startKeepalive();
          onAuthenticated?.call();
          chat.flushOutbox();
          notifyListeners();
          break;
        case 'auth_error':
          _terminalAuthError = true;
          _connectionError = msg['error'] as String? ?? 'Authentication failed';
          _isReconnecting = false;
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          ErrorLogger.I.log(
            provider: 'websocket',
            context: 'ws.auth',
            error: msg['error'] ?? 'Unknown auth error',
          );
          notifyListeners();
          break;
        case 'peer_joined':
          _isPeerConnected = true;
          final peerKey = msg['peerAgreementPublicKey'] as String?;
          if (peerKey != null && peerKey.isNotEmpty) {
            unawaited(_configureConversationCrypto(peerKey).then((_) {
              chat.flushOutbox();
            }));
          } else {
            chat.flushOutbox();
          }
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
          unawaited(chat
              .addIncomingChatSecure(Map<String, dynamic>.from(msg))
              .then((_) {
            chat.persistConversation();
            notifyListeners();
          }));
          break;
        case 'voice':
          // The relay forwards voice notes (base64 audio, capped at 64 KB) and
          // stores them in the history. Without this case the app dropped them
          // silently, so the whole feature was unreachable.
          unawaited(chat
              .addIncomingVoice(Map<String, dynamic>.from(msg))
              .then((_) {
            chat.persistConversation();
            notifyListeners();
          }));
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
          unawaited(chat.replaceHistorySecure(history));
          break;
        case 'edit':
          // The peer edited their own message; the relay already checked
          // ownership before forwarding.
          chat.applyRemoteEdit(Map<String, dynamic>.from(msg));
          chat.persistConversation();
          notifyListeners();
          break;
        case 'delete':
          // The peer deleted their own message.
          chat.applyRemoteDelete(Map<String, dynamic>.from(msg));
          chat.persistConversation();
          notifyListeners();
          break;
        case 'signal':
          if (_signals.length >= _maxSignals) _signals.removeAt(0);
          _signals
              .add({'signalType': msg['signalType'], 'signal': msg['signal']});
          onSignal?.call(msg['signalType'] as String, msg['signal']);
          notifyListeners();
          break;
        case 'subtitle':
          // Guide mode: the host's translated line. The screen filters by its
          // own language; the relay fans every language out to everyone.
          onSubtitle?.call(Map<String, dynamic>.from(msg));
          notifyListeners();
          break;
        case 'listener_joined':
        case 'listener_left':
          final count = msg['count'];
          if (count is int) {
            _listenerCount = count;
            onListenerCountChanged?.call(count);
          }
          // Track the roster so the guide can remove a specific listener.
          final listenerId = msg['listenerId'] as String?;
          if (listenerId != null && listenerId.isNotEmpty) {
            if (msg['type'] == 'listener_joined') {
              if (!_listenerIds.contains(listenerId)) _listenerIds.add(listenerId);
            } else {
              _listenerIds.remove(listenerId);
            }
            onListenerListChanged?.call(List.unmodifiable(_listenerIds));
          }
          notifyListeners();
          break;
        case 'listener_kicked':
          // The guide removed this device from the audience. Surface it so
          // the listener screen can leave instead of sitting on a dead
          // connection. Deferred: this runs inside the socket's message
          // dispatch, and a listener that tears its tree down synchronously
          // here trips "setState() called when widget tree was locked".
          final kicked = onKicked;
          if (kicked != null) {
            scheduleMicrotask(kicked);
          }
          notifyListeners();
          break;
        case 'contact_request':
          onContactRequest?.call(Map<String, dynamic>.from(msg));
          notifyListeners();
          break;
        case 'contact_response':
          onContactResponse?.call(Map<String, dynamic>.from(msg));
          notifyListeners();
          break;
        case 'error':
          ErrorLogger.I.log(
            provider: 'websocket',
            context: 'ws.message',
            error: msg['error'] ?? 'Unknown error',
          );
          break;
        case 'ping':
        case 'pong':
          // Keepalive answer. Receiving it is the whole point — it proves the
          // socket is still alive, so there is nothing to handle.
          break;
        default:
          ErrorLogger.I.log(
            provider: 'websocket',
            context: 'ws.unknown_message',
            error: 'Unknown message type: ${msg['type']}',
          );
          break;
      }
    } catch (e) {
      debugPrint('[Snail] ws.onMessage decode error: $e');
    }
  }

  Future<void> _configureConversationCrypto(String peerPublicKey) async {
    final derive = sharedSecretDeriver;
    if (derive == null) return;
    final sharedSecret = await derive(peerPublicKey);
    if (sharedSecret == null || sharedSecret.isEmpty) return;
    try {
      chat.setConversationCrypto(
          ChatCryptoService.fromBase64SharedSecret(sharedSecret));
    } catch (error, stackTrace) {
      ErrorLogger.I.log(
        provider: 'chat',
        context: 'conversation_key.invalid',
        error: error,
        stackTrace: stackTrace,
      );
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
    chat.markTransportUnavailable();
    notifyListeners();
    chat.persistConversation(immediate: true);
    _tryReconnect();
  }

  void _onDone() {
    _isConnected = false;
    _isAuthenticated = false;
    _isPeerConnected = false;
    chat.markTransportUnavailable();
    notifyListeners();
    _tryReconnect();
  }

  void _tryReconnect() {
    if (_isConnected || _reconnectTimer != null || _terminalAuthError) return;
    if (_reconnectAttempt >= _reconnectDelays.length) {
      _isReconnecting = false;
      // All retries failed: surface this to the UI so the user is not left
      // staring at "waiting for connection" forever.
      _reconnectExhausted = true;
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

  /// Chat uses its own data channel, so its readiness is checked separately
  /// from the audio channel (`isP2pConnected`).
  bool Function()? isP2pChatConnected;
  void Function(Map<String, dynamic> message)? p2pChatSend;

  void sendPcmAudio(Uint8List pcm16, {int sampleRate = 24000}) {
    if (!_isConnected || _isMuted || pcm16.isEmpty) return;
    _channel?.sink.add(_framePcm(pcm16, sampleRate, 2));
  }

  void sendPcmAudioEnd() {
    if (!_isConnected || _isMuted) return;
    _channel?.sink.add(_framePcm(Uint8List(0), 0, 2));
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
    _channel?.sink.add(_framePcm(pcm16, sampleRate, 3));
  }

  Uint8List _framePcm(Uint8List pcm16, int sampleRate, int kind) {
    final frame = Uint8List(5 + pcm16.length);
    frame[0] = kind;
    ByteData.sublistView(frame, 1, 5).setUint32(0, sampleRate, Endian.little);
    frame.setRange(5, frame.length, pcm16);
    return frame;
  }

  void sendSignal(String signalType, dynamic signal) {
    if (!_isConnected || !_isAuthenticated) return;
    _channel?.sink.add(jsonEncode({
      'type': 'signal',
      'signalType': signalType,
      'signal': signal,
    }));
  }

  /// Guide mode: publish one translated line to the audience.
  ///
  /// Every listener receives every language and filters locally, so a
  /// listener can switch languages without re-subscribing.
  void sendSubtitle({
    required String text,
    required String sourceLang,
    required String targetLang,
    String? messageId,
  }) {
    if (!_isConnected || !_isAuthenticated || text.trim().isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'subtitle',
      if (messageId != null) 'messageId': messageId,
      'text': text,
      'sourceLang': sourceLang,
      'targetLang': targetLang,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  /// Guide mode: remove one listener from the audience.
  void sendListenerKick(String listenerId) {
    if (!_isConnected || !_isAuthenticated || listenerId.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'listener_kick',
      'listenerId': listenerId,
    }));
  }

  /// Asks the connected peer to become a contact.
  ///
  /// Carries this device's own id and agreement key so the peer can store a
  /// usable contact without a second round trip.
  void sendContactRequest({
    required String userId,
    String? username,
    String? agreementPublicKey,
  }) {
    if (!_isConnected || !_isAuthenticated || userId.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'contact_request',
      'userId': userId,
      if (username != null && username.isNotEmpty) 'text': username,
      if (agreementPublicKey != null && agreementPublicKey.isNotEmpty)
        'agreementPublicKey': agreementPublicKey,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  /// Answers a contact request from the peer.
  void sendContactResponse({
    required String userId,
    required bool accepted,
  }) {
    if (!_isConnected || !_isAuthenticated || userId.isEmpty) return;
    _channel?.sink.add(jsonEncode({
      'type': 'contact_response',
      'userId': userId,
      'accepted': accepted,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopKeepalive();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _isAuthenticated = false;
    _isPeerConnected = false;
    chat.markTransportUnavailable();
    _isReconnecting = false;
    _fishTtsConfig = null;
    chat.persistConversation(immediate: true);
    // A screen may disconnect while it is being disposed; notifying then
    // throws "A AudioService was used after being disposed".
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
