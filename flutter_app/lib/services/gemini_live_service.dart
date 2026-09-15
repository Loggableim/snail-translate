import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'live_translation_provider.dart';
import 'error_logger.dart';

/// Immutable, completed section of one Gemini Live translation stream.
class GeminiTurn {
  const GeminiTurn({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.sourceText,
    required this.targetText,
  });

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final String sourceText;
  final String targetText;
}

/// Low-level Gemini Live Translation transport.
///
/// The session owner supplies the BYOK key. This service accepts 16 kHz mono
/// PCM16 input and exposes translated 24 kHz PCM16 chunks to the playback
/// layer. Ephemeral Google tokens can replace the key in the future without
/// changing the wire protocol.
class GeminiLiveService extends ChangeNotifier
    implements LiveTranslationProvider {
  static const _maxAudioChunks = 96;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _connected = false;
  String _state = 'idle';
  String? _lastError;
  String? _apiKey;
  String? _targetLanguage;
  String _model = 'gemini-3.5-live-translate-preview';
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  bool _closing = false;
  static const _reconnectDelays = <Duration>[
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];
  String _inputTranscript = '';
  String _outputTranscript = '';
  final List<Uint8List> _audioChunks = [];
  // Completed source/target transcript pairs, exposed for history
  // persistence. Gemini Live marks a turn with `turnComplete`.
  final List<GeminiTurn> _completedTurns = <GeminiTurn>[];
  int _turnSequence = 0;
  int? _turnInputOffset;
  int? _turnOutputOffset;
  DateTime? _turnStartedAt;

  /// Completed, non-empty turns exactly once for persistence/UI.
  List<GeminiTurn> takeCompletedTurns() {
    final result = List<GeminiTurn>.from(_completedTurns);
    _completedTurns.clear();
    return result;
  }

  bool get isConnected => _connected;
  @override
  String get state => _state;
  @override
  String? get lastError => _lastError;
  String get inputTranscript => _inputTranscript;
  String get outputTranscript => _outputTranscript;
  List<Uint8List> takeAudioChunks() {
    final chunks = List<Uint8List>.from(_audioChunks);
    _audioChunks.clear();
    return chunks;
  }

  Future<void> connect(
      {required String apiKey,
      required String targetLanguage,
      String model = 'gemini-3.5-live-translate-preview'}) async {
    if (apiKey.trim().isEmpty) throw ArgumentError('Gemini BYOK-Key fehlt');
    _closing = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _apiKey = apiKey.trim();
    _targetLanguage = targetLanguage;
    _model = model;
    _inputTranscript = '';
    _outputTranscript = '';
    _completedTurns.clear();
    _turnSequence = 0;
    _turnInputOffset = null;
    _turnOutputOffset = null;
    _turnStartedAt = null;
    await _connectInternal();
  }

  Future<void> _connectInternal() async {
    final apiKey = _apiKey;
    final targetLanguage = _targetLanguage;
    if (apiKey == null || targetLanguage == null || _closing) return;
    _state = 'connecting';
    _lastError = null;
    notifyListeners();
    final uri = Uri.parse(
        'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${Uri.encodeQueryComponent(apiKey)}');
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      if (_closing) return;
      _connected = true;
      _state = 'ready';
      _reconnectAttempt = 0;
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _channel!.sink.add(jsonEncode({
        'setup': {
          'model': 'models/$_model',
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'inputAudioTranscription': {},
            'outputAudioTranscription': {},
            'translationConfig': {
              'targetLanguageCode': targetLanguage,
              'echoTargetLanguage': true
            },
          },
        },
      }));
      notifyListeners();
    } catch (error, stackTrace) {
      _connected = false;
      _state = 'degraded';
      _lastError = error.toString();
      ErrorLogger.I.log(
        provider: 'gemini',
        context: 'realtime.connect',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void sendPcm16(Uint8List pcm16At16kHz) {
    if (!_connected) return;
    _channel?.sink.add(jsonEncode({
      'realtimeInput': {
        'audio': {
          'data': base64Encode(pcm16At16kHz),
          'mimeType': 'audio/pcm;rate=16000'
        }
      }
    }));
  }

  void _onMessage(dynamic raw) {
    try {
      final content = (jsonDecode(raw as String)
          as Map<String, dynamic>)['serverContent'] as Map<String, dynamic>?;
      if (content == null) return;
      final input = content['inputTranscription'] as Map<String, dynamic>?;
      final output = content['outputTranscription'] as Map<String, dynamic>?;
      if (input?['text'] is String) {
        _inputTranscript += input!['text'] as String;
      }
      if (output?['text'] is String) {
        _outputTranscript += output!['text'] as String;
      }
      final parts =
          content['modelTurn']?['parts'] as List<dynamic>? ?? const [];
      for (final part in parts) {
        final inline = (part as Map<String, dynamic>)['inlineData']
            as Map<String, dynamic>?;
        final data = inline?['data'];
        if (data is String) {
          if (_audioChunks.length >= _maxAudioChunks) _audioChunks.removeAt(0);
          _audioChunks.add(Uint8List.fromList(base64Decode(data)));
        }
      }
      if (content['turnComplete'] == true) _finalizeTurn();
      notifyListeners();
    } catch (error) {
      debugPrint('[Snail] Gemini event error: $error');
    }
  }

  /// Slices the completed turn out of the running transcripts. Offsets are
  /// captured lazily so a turn that started before this listener ran still
  /// produces a sensible slice.
  void _finalizeTurn() {
    final inputStart = _turnInputOffset ?? 0;
    final outputStart = _turnOutputOffset ?? 0;
    final sourceText = _inputTranscript
        .substring(inputStart.clamp(0, _inputTranscript.length))
        .trim();
    final targetText = _outputTranscript
        .substring(outputStart.clamp(0, _outputTranscript.length))
        .trim();
    _turnInputOffset = _inputTranscript.length;
    _turnOutputOffset = _outputTranscript.length;
    if (sourceText.isEmpty && targetText.isEmpty) return;
    _completedTurns.add(GeminiTurn(
      id: 'gemini-${++_turnSequence}',
      startedAt: _turnStartedAt ?? DateTime.now(),
      endedAt: DateTime.now(),
      sourceText: sourceText,
      targetText: targetText,
    ));
    _turnStartedAt = DateTime.now();
    if (_completedTurns.length > 64) _completedTurns.removeAt(0);
  }

  void _onError(Object error) {
    _connected = false;
    _state = 'degraded';
    _lastError = error.toString();
    ErrorLogger.I
        .log(provider: 'gemini', context: 'realtime.socket', error: error);
    notifyListeners();
    _scheduleReconnect();
  }

  void _onDone() {
    _connected = false;
    _state = 'closed';
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closing ||
        _reconnectTimer != null ||
        _reconnectAttempt >= _reconnectDelays.length) {
      if (!_closing && _reconnectAttempt >= _reconnectDelays.length) {
        _state = 'error';
        notifyListeners();
      }
      return;
    }
    final delay = _reconnectDelays[_reconnectAttempt++];
    _state = 'reconnecting';
    notifyListeners();
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      await _connectInternal();
    });
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _connected = false;
    _state = 'idle';
    // dispose() may already have marked this ChangeNotifier disposed; a
    // pending reconnect timer or caller can still invoke disconnect after
    // that, and notifyListeners on a disposed notifier throws.
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
