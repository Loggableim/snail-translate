import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'audio_processor.dart';
import 'error_logger.dart';

/// Immutable, completed section of one continuous translation stream.
class RealtimeTurn {
  const RealtimeTurn({
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

/// Client for OpenAI's dedicated realtime translation endpoint.
///
/// The translation protocol is continuous: callers append 24 kHz mono PCM16
/// and consume audio and transcript deltas as they arrive. There is no
/// response.create lifecycle for this endpoint.
class OpenAiRealtimeService extends ChangeNotifier {
  static const _endpoint = 'wss://api.openai.com/v1/realtime/translations';
  static const _model = 'gpt-realtime-translate';
  static const _maxAudioChunks = 96;

  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _connected = false;
  bool _closing = false;
  String? _apiKey;
  String? _targetLanguage;
  String _safetyIdentifier = 'snail-device-session';
  Future<String?> Function()? _credentialRefresher;
  String _state = 'idle';
  String _inputTranscript = '';
  String _outputTranscript = '';
  String? _lastError;
  int _droppedAudioChunks = 0;
  int _audioDeltaCount = 0;
  int _speechStarts = 0;
  int _speechStops = 0;
  final List<Uint8List> _audioChunks = <Uint8List>[];
  Completer<void>? _closeCompleter;
  Stopwatch? _latencyClock;
  bool _loggedFirstInput = false;
  bool _loggedFirstOutput = false;
  Timer? _reconnectTimer;
  Timer? _turnFinalizeTimer;
  int _reconnectAttempts = 0;
  int _turnSequence = 0;
  int? _turnInputOffset;
  int? _turnOutputOffset;
  DateTime? _turnStartedAt;
  DateTime? _firstInputAt;
  DateTime? _firstOutputAudioAt;
  DateTime? _firstInputTranscriptAt;
  DateTime? _firstOutputTranscriptAt;
  final List<RealtimeTurn> _completedTurns = <RealtimeTurn>[];
  // Mobile Wi-Fi and Android Doze can cause a short sequence of socket
  // failures. Keep recovery bounded, but cover the normal handover window.
  static const _maxReconnectAttempts = 6;

  bool get isConnected => _connected;
  String get state => _state;
  String get inputTranscript => _inputTranscript;
  String get outputTranscript => _outputTranscript;
  String? get lastError => _lastError;
  int get droppedAudioChunks => _droppedAudioChunks;
  int get audioDeltaCount => _audioDeltaCount;
  int get speechStarts => _speechStarts;
  int get speechStops => _speechStops;
  bool get hasPendingAudio => _audioChunks.isNotEmpty;
  Duration? get timeToFirstAudio =>
      _firstInputAt == null || _firstOutputAudioAt == null
          ? null
          : _firstOutputAudioAt!.difference(_firstInputAt!);
  Duration? get timeToFirstTranscript =>
      _firstInputAt == null || _firstOutputTranscriptAt == null
          ? null
          : _firstOutputTranscriptAt!.difference(_firstInputAt!);

  /// Returns completed, non-empty turns exactly once for persistence/UI.
  List<RealtimeTurn> takeCompletedTurns() {
    final result = List<RealtimeTurn>.from(_completedTurns);
    _completedTurns.clear();
    return result;
  }

  /// Removes and returns all output audio currently waiting for playback.
  List<Uint8List> takeAudioChunks() {
    final result = List<Uint8List>.from(_audioChunks);
    _audioChunks.clear();
    return result;
  }

  /// Clears only the not-yet-played audio. Already played audio cannot be
  /// interrupted by the provider and is handled by the native audio layer.
  void flushAudio() {
    _audioChunks.clear();
    notifyListeners();
  }

  void clearTranscripts() {
    _inputTranscript = '';
    _outputTranscript = '';
    notifyListeners();
  }

  Future<void> connect(
      {required String apiKey,
      required String targetLanguage,
      String? safetyIdentifier,
      Future<String?> Function()? credentialRefresher}) async {
    if (apiKey.trim().isEmpty) throw ArgumentError('OpenAI BYOK-Key fehlt');
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    _closing = false;
    await _closeTransport();
    _apiKey = apiKey.trim();
    _targetLanguage = targetLanguage.trim().toLowerCase();
    _safetyIdentifier = safetyIdentifier?.trim().isNotEmpty == true
        ? safetyIdentifier!.trim()
        : 'snail-device-session';
    _credentialRefresher = credentialRefresher;
    _inputTranscript = '';
    _outputTranscript = '';
    _lastError = null;
    _droppedAudioChunks = 0;
    _audioDeltaCount = 0;
    _speechStarts = 0;
    _speechStops = 0;
    _turnSequence = 0;
    _turnInputOffset = null;
    _turnOutputOffset = null;
    _turnStartedAt = null;
    _firstInputAt = null;
    _firstOutputAudioAt = null;
    _firstInputTranscriptAt = null;
    _firstOutputTranscriptAt = null;
    _completedTurns.clear();
    await _openTransport();
  }

  Future<void> _openTransport() async {
    final key = _apiKey;
    final language = _targetLanguage;
    if (key == null || language == null || language.isEmpty) return;
    _state = 'connecting';
    notifyListeners();
    final uri = Uri.parse('$_endpoint?model=$_model');
    try {
      final channel = IOWebSocketChannel.connect(uri, headers: {
        'Authorization': 'Bearer $key',
        // Stable pseudonymous app identifier; never a key or display name.
        'OpenAI-Safety-Identifier': _safetyIdentifier,
      });
      _channel = channel;
      await channel.ready;
      if (_closing) return;
      _connected = true;
      _state = 'ready';
      _latencyClock = Stopwatch()..start();
      _loggedFirstInput = false;
      _loggedFirstOutput = false;
      debugPrint('[SnailRealtime] ready id=${identityHashCode(this)}');
      _subscription = channel.stream.listen(
        (raw) {
          if (identical(_channel, channel)) _onMessage(raw);
        },
        onError: (Object error) {
          if (identical(_channel, channel)) _onError(error);
        },
        onDone: () {
          if (identical(_channel, channel)) _onDone();
        },
        cancelOnError: false,
      );
      channel.sink.add(jsonEncode({
        'type': 'session.update',
        'session': {
          'audio': {
            'output': {'language': language}
          }
        },
      }));
      notifyListeners();
    } catch (error, stackTrace) {
      _recordError('realtime.connect', error, stackTrace);
      _connected = false;
      // The first connection attempt can fail before a WebSocket stream
      // exists (for example Android DNS/network handover during join). Treat
      // it like a transport loss as well; otherwise the joiner remains stuck
      // on `Realtime: error` and never reaches the existing bounded recovery
      // path.
      if (!_closing) {
        _state = 'reconnecting';
        _scheduleReconnect();
      } else {
        _state = 'error';
      }
      rethrow;
    }
  }

  /// OpenAI's WebSocket translation transport requires 24-kHz PCM16.
  /// Snail's native capture runs at 16 kHz, so resampling happens here.
  void sendPcm16(Uint8List bytes, {int inputSampleRate = 16000}) {
    if (!_connected || bytes.isEmpty || _channel == null) return;
    if (!_loggedFirstInput) {
      _loggedFirstInput = true;
      _firstInputAt = DateTime.now();
      debugPrint(
          '[SnailRealtime] first_input id=${identityHashCode(this)} ms=${_latencyClock?.elapsedMilliseconds}');
    }
    final pcm24 = inputSampleRate == 24000
        ? bytes
        : AudioProcessor.processAudioChunk(bytes, inputSampleRate, 24000);
    try {
      _channel!.sink.add(jsonEncode({
        'type': 'session.input_audio_buffer.append',
        'audio': base64Encode(pcm24)
      }));
    } catch (error) {
      // A locally closed socket may throw before its stream invokes onDone.
      // Treat it like a transport loss so capture can recover automatically.
      _onError(error);
      return;
    }
    if (_state == 'ready') {
      _state = 'streaming';
      notifyListeners();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final event = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = event['type'];
      switch (type) {
        case 'session.output_audio.delta':
          final delta = event['delta'];
          if (delta is String) {
            if (!_loggedFirstOutput) {
              _loggedFirstOutput = true;
              _firstOutputAudioAt = DateTime.now();
              debugPrint(
                  '[SnailRealtime] first_output id=${identityHashCode(this)} ms=${_latencyClock?.elapsedMilliseconds}');
            }
            if (_audioChunks.length >= _maxAudioChunks) {
              _audioChunks.removeAt(0);
              _droppedAudioChunks++;
            }
            _audioChunks.add(Uint8List.fromList(base64Decode(delta)));
            _audioDeltaCount++;
            notifyListeners();
          }
          break;
        case 'session.input_transcript.delta':
          final delta = event['delta'];
          if (delta is String) {
            _firstInputTranscriptAt ??= DateTime.now();
            _inputTranscript += delta;
            notifyListeners();
          }
          break;
        case 'session.output_transcript.delta':
          final delta = event['delta'];
          if (delta is String) {
            _firstOutputTranscriptAt ??= DateTime.now();
            _outputTranscript += delta;
            if (_turnFinalizeTimer != null) _scheduleTurnFinalize();
            notifyListeners();
          }
          break;
        case 'input_audio_buffer.speech_started':
          _turnFinalizeTimer?.cancel();
          _turnFinalizeTimer = null;
          _turnInputOffset ??= _inputTranscript.length;
          _turnOutputOffset ??= _outputTranscript.length;
          _turnStartedAt ??= DateTime.now();
          _speechStarts++;
          notifyListeners();
          break;
        case 'input_audio_buffer.speech_stopped':
          _speechStops++;
          _scheduleTurnFinalize();
          notifyListeners();
          break;
        case 'session.closed':
          if (!(_closeCompleter?.isCompleted ?? true)) {
            _closeCompleter!.complete();
          }
          _connected = false;
          _state = 'closed';
          notifyListeners();
          break;
        case 'error':
          final error = event['error'];
          _recordError(
              'realtime.event',
              error is Map
                  ? (error['message'] ?? error.toString())
                  : (error ?? 'Realtime API error'),
              null);
          // Translation sessions can surface a terminal server-side error
          // before the WebSocket closes. Expose it as degraded and attempt the
          // same bounded recovery path used for normal transport loss.
          _connected = false;
          if (!_closing) _state = 'degraded';
          notifyListeners();
          _scheduleReconnect();
          break;
        default:
          // Keep unknown events observable without failing the audio stream.
          debugPrint('[SnailRealtime] event=$type');
      }
    } catch (error, stackTrace) {
      _recordError('realtime.decode', error, stackTrace);
    }
  }

  /// Wait briefly for the final target transcript delta before committing a
  /// completed turn. This keeps partial, reconnecting turns out of history.
  void _scheduleTurnFinalize() {
    _turnFinalizeTimer?.cancel();
    _turnFinalizeTimer = Timer(const Duration(milliseconds: 900), () {
      final inputOffset = _turnInputOffset;
      final outputOffset = _turnOutputOffset;
      final startedAt = _turnStartedAt;
      _turnFinalizeTimer = null;
      _turnInputOffset = null;
      _turnOutputOffset = null;
      _turnStartedAt = null;
      if (inputOffset == null || outputOffset == null || startedAt == null) {
        return;
      }
      final source = _inputTranscript.substring(inputOffset).trim();
      final target = _outputTranscript.substring(outputOffset).trim();
      if (source.isEmpty || target.isEmpty) return;
      _completedTurns.add(RealtimeTurn(
        id: '${identityHashCode(this)}-${++_turnSequence}',
        startedAt: startedAt,
        endedAt: DateTime.now(),
        sourceText: source,
        targetText: target,
      ));
      notifyListeners();
    });
  }

  void _recordError(String context, Object error, StackTrace? stackTrace) {
    _lastError = error.toString();
    ErrorLogger.I.log(
        provider: 'openai',
        context: context,
        error: error,
        stackTrace: stackTrace);
    notifyListeners();
  }

  void _onError(Object error) {
    _recordError('realtime.websocket', error, null);
    _connected = false;
    if (!_closing) _state = 'degraded';
    notifyListeners();
    _scheduleReconnect();
  }

  void _onDone() {
    if (!(_closeCompleter?.isCompleted ?? true)) _closeCompleter!.complete();
    _connected = false;
    if (!_closing) _state = 'degraded';
    notifyListeners();
    _scheduleReconnect();
  }

  /// Recovers short network interruptions without replaying buffered audio.
  /// If the credential itself expired or the connection remains unavailable,
  /// the UI stays in `degraded` and the caller can establish a fresh session.
  void _scheduleReconnect() {
    if (_closing || _apiKey == null || _reconnectTimer != null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _state = 'reconnecting';
    // Discard any audio still buffered from the old connection to prevent
    // double playback when the new connection starts producing output.
    _audioChunks.clear();
    notifyListeners();
    final delay = Duration(milliseconds: 500 * (1 << _reconnectAttempts));
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      if (_closing || _connected || _apiKey == null) return;
      try {
        await _closeTransport();
        if (_credentialRefresher != null) {
          final refreshed = await _credentialRefresher!();
          if (refreshed == null || refreshed.trim().isEmpty) {
            throw StateError(
                'Realtime client secret konnte nicht erneuert werden');
          }
          _apiKey = refreshed.trim();
        }
        await _openTransport();
        _reconnectAttempts = 0;
      } catch (_) {
        // _openTransport records the failure; the bounded retry remains
        // intentionally quiet so an expired client secret cannot loop forever.
        _scheduleReconnect();
      }
    });
  }

  Future<void> disconnect() async {
    _closing = true;
    _turnFinalizeTimer?.cancel();
    _turnFinalizeTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeTransport();
    _apiKey = null;
    _targetLanguage = null;
    _credentialRefresher = null;
    _state = 'idle';
    _closing = false;
    notifyListeners();
  }

  Future<void> _closeTransport() async {
    if (_channel == null && _subscription == null) return;
    if (_connected && _channel != null) {
      _closeCompleter = Completer<void>();
      try {
        _state = 'draining';
        _channel!.sink.add(jsonEncode({'type': 'session.close'}));
        await _closeCompleter!.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        debugPrint('[SnailRealtime] close drain timeout');
      } catch (_) {}
    }
    await _subscription?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _subscription = null;
    _channel = null;
    _connected = false;
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _turnFinalizeTimer?.cancel();
    disconnect();
    super.dispose();
  }
}
