import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Low-level Gemini Live Translation transport.
///
/// The session owner supplies the BYOK key. This service accepts 16 kHz mono
/// PCM16 input and exposes translated 24 kHz PCM16 chunks to the playback
/// layer. Ephemeral Google tokens can replace the key in the future without
/// changing the wire protocol.
class GeminiLiveService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _connected = false;
  String _inputTranscript = '';
  String _outputTranscript = '';
  final List<Uint8List> _audioChunks = [];

  bool get isConnected => _connected;
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
    final uri = Uri.parse(
        'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${Uri.encodeQueryComponent(apiKey)}');
    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;
    _connected = true;
    _subscription =
        _channel!.stream.listen(_onMessage, onError: _onError, onDone: _onDone);
    _channel!.sink.add(jsonEncode({
      'setup': {
        'model': 'models/$model',
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
          _audioChunks.add(Uint8List.fromList(base64Decode(data)));
        }
      }
      notifyListeners();
    } catch (error) {
      debugPrint('[Snail] Gemini event error: $error');
    }
  }

  void _onError(Object error) {
    _connected = false;
    notifyListeners();
  }

  void _onDone() {
    _connected = false;
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _connected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
