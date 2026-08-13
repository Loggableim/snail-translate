import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:web_socket_channel/io.dart';

/// Fish Audio's documented realtime TTS transport.
///
/// Fish Audio is the low-cost speech leg of Snail's translation pipeline:
/// STT/MT produces translated text, then this service streams that text to
/// Fish Audio and exposes binary audio chunks to the playback queue.
class FishAudioRealtimeService extends ChangeNotifier {
  static const endpoint = 'wss://api.fish.audio/v1/tts/live';
  static const _maxBufferedChunks = 24;

  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final List<Uint8List> _audioChunks = <Uint8List>[];
  final StringBuffer _textBuffer = StringBuffer();
  bool _connected = false;
  String _state = 'idle';
  String? _lastError;
  String? _apiKey;
  String _voiceId = '802e3bc2b27e49c2995d23ef70e6ac89';
  String _latency = 'balanced';
  String _model = 's2-pro';
  double _temperature = 0.7;
  double _topP = 0.7;
  double _speed = 1.0;
  int _reconnectAttempts = 0;
  Timer? _retryTimer;
  bool _disposed = false;

  bool get isConnected => _connected;
  String get state => _state;
  String? get lastError => _lastError;
  bool get hasPendingAudio => _audioChunks.isNotEmpty;
  int get pendingTextWords => _wordCount(_textBuffer.toString());
  String get voiceId => _voiceId;

  Future<void> connect({
    required String apiKey,
    required String voiceId,
    String latency = 'balanced',
    String model = 's2-pro',
    double temperature = 0.7,
    double topP = 0.7,
    double speed = 1.0,
  }) async {
    if (apiKey.trim().isEmpty) throw ArgumentError('Fish-Audio-Key fehlt');
    await disconnect();
    _apiKey = apiKey.trim();
    _voiceId = voiceId.trim();
    _latency =
        const ['balanced', 'normal'].contains(latency) ? latency : 'balanced';
    _model = model.trim().isEmpty ? 's2-pro' : model.trim();
    _temperature = temperature.clamp(0.0, 1.0);
    _topP = topP.clamp(0.0, 1.0);
    _speed = speed.clamp(0.5, 2.0);
    _reconnectAttempts = 0;
    _lastError = null;
    await _open();
  }

  /// Switches the voice for the local speaker without changing the API key or
  /// the rest of the provider configuration. Fish binds reference_id to the
  /// websocket session, so reconnecting is required.
  Future<void> changeVoice(String voiceId) async {
    final key = _apiKey;
    if (key == null || key.isEmpty || voiceId.trim().isEmpty) return;
    await connect(
      apiKey: key,
      voiceId: voiceId,
      latency: _latency,
      model: _model,
      temperature: _temperature,
      topP: _topP,
      speed: _speed,
    );
  }

  /// Switches voice between completed turns without losing provider settings.
  /// Fish binds the voice to the TTS session, so a fresh session is required.
  Future<void> switchVoice(String voiceId) async {
    final nextVoice = voiceId.trim();
    if (nextVoice.isEmpty) throw ArgumentError('Fish-Voice-ID fehlt');
    final key = _apiKey;
    if (key == null || !_connected) {
      _voiceId = nextVoice;
      return;
    }
    flush();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await disconnect();
    _apiKey = key;
    _voiceId = nextVoice;
    _reconnectAttempts = 0;
    await _open();
  }

  Future<void> _open() async {
    final key = _apiKey;
    if (key == null) return;
    _state = 'connecting';
    if (!_disposed) notifyListeners();
    try {
      // Fish documents `model` as a WebSocket binding/header, not a field in
      // the MessagePack event.  Keep the wire format aligned with that API.
      final channel = IOWebSocketChannel.connect(Uri.parse(endpoint), headers: {
        'Authorization': 'Bearer $key',
        'model': _model,
      });
      _channel = channel;
      await channel.ready;
      _connected = true;
      _state = 'ready';
      _send({
        'event': 'start',
        'request': {
          'text': '',
          // The Android audio bridge consumes mono PCM16.  MP3 is the Fish
          // default, but passing it to playPcm16 would produce noise.
          'format': 'pcm',
          'sample_rate': 24000,
          'chunk_length': 300,
          'reference_id': _voiceId,
          'latency': _latency,
          'temperature': _temperature,
          'top_p': _topP,
          'prosody': {'speed': _speed},
        }
      });
      _subscription = channel.stream.listen(_onMessage,
          onError: (Object error, StackTrace stack) => _onTransportError(error),
          onDone: _onClosed,
          cancelOnError: false);
      if (!_disposed) notifyListeners();
    } catch (error) {
      _onTransportError(error);
      rethrow;
    }
  }

  /// Sends complete words/phrases. Callers should buffer 5–10 words.
  void sendText(String text) {
    final normalized = text.trim();
    if (!_connected || normalized.isEmpty) return;
    if (_textBuffer.isNotEmpty) _textBuffer.write(' ');
    _textBuffer.write(normalized);
    final buffered = _textBuffer.toString();
    if (_wordCount(buffered) >= 5 || RegExp(r'[.!?。！？]$').hasMatch(buffered)) {
      _sendBufferedText();
    }
  }

  void flush() {
    if (!_connected) return;
    _sendBufferedText();
    _send({'event': 'flush'});
  }

  void _sendBufferedText() {
    final text = _textBuffer.toString().trim();
    if (text.isEmpty) return;
    _send({'event': 'text', 'text': '$text '});
    _textBuffer.clear();
  }

  static int _wordCount(String text) =>
      text.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;

  List<Uint8List> takeAudioChunks() {
    final result = List<Uint8List>.from(_audioChunks);
    _audioChunks.clear();
    // The pending text buffer belongs to the *next* utterance. Clearing it
    // here discarded a translation whenever audio for the previous turn
    // arrived before the buffer reached the word/punctuation flush threshold.
    return result;
  }

  void _send(Map<String, dynamic> value) {
    _channel?.sink.add(encodeEvent(value));
  }

  /// Encodes the documented Fish realtime event for protocol-level tests and
  /// transport adapters. The payload remains MessagePack binary on the wire.
  static Uint8List encodeEvent(Map<String, dynamic> value) {
    return Uint8List.fromList(msgpack.serialize(<String, dynamic>{...value}));
  }

  void _onMessage(dynamic raw) {
    if (raw is! List<int>) return;
    try {
      final decoded = msgpack.deserialize(Uint8List.fromList(raw));
      if (decoded is! Map) return;
      final event = decoded['event']?.toString();
      if (event == 'audio' || decoded.containsKey('audio')) {
        final bytes = decoded['audio'];
        if (bytes is List<int>) _enqueue(Uint8List.fromList(bytes));
        if (bytes is Uint8List) _enqueue(bytes);
      }
      if (event == 'finish' || event == 'close') _state = 'ready';
      if (event == 'error') _lastError = decoded['message']?.toString();
      if (!_disposed) notifyListeners();
    } catch (error) {
      _lastError = 'Fish-Audio MessagePack-Fehler: $error';
      _state = 'error';
      if (!_disposed) notifyListeners();
    }
  }

  void _enqueue(Uint8List chunk) {
    if (_audioChunks.length >= _maxBufferedChunks) _audioChunks.removeAt(0);
    _audioChunks.add(chunk);
  }

  void _onTransportError(Object error) {
    _lastError = error.toString();
    _connected = false;
    _state = 'degraded';
    if (!_disposed) notifyListeners();
    _scheduleRetry();
  }

  void _onClosed() {
    _connected = false;
    if (_state != 'idle') {
      _state = 'degraded';
      _scheduleRetry();
    }
    if (!_disposed) notifyListeners();
  }

  void _scheduleRetry() {
    if (_apiKey == null || _retryTimer != null || _reconnectAttempts >= 4)
      return;
    final delay = Duration(milliseconds: 300 * (1 << _reconnectAttempts));
    _reconnectAttempts++;
    _retryTimer = Timer(delay, () async {
      _retryTimer = null;
      try {
        await _open();
      } catch (_) {}
    });
  }

  Future<void> disconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _apiKey = null;
    _connected = false;
    _state = 'idle';
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _audioChunks.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
