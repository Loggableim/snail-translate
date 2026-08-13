import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Fish Audio v1 speech-to-text client.
///
/// Fish's ASR endpoint accepts an audio file, so the realtime coordinator
/// should accumulate a short utterance locally and submit it at a speech
/// boundary. This keeps the provider-specific wire format out of the UI.
class FishAudioAsrService {
  static const endpoint = 'https://api.fish.audio/v1/asr';

  Future<String> transcribe({
    required String apiKey,
    required Uint8List pcm16,
    required int sampleRate,
    String? language,
  }) async {
    final result = await transcribeDetected(
      apiKey: apiKey,
      pcm16: pcm16,
      sampleRate: sampleRate,
      language: language,
    );
    return result.text;
  }

  Future<FishAsrTranscript> transcribeDetected({
    required String apiKey,
    required Uint8List pcm16,
    required int sampleRate,
    String? language,
  }) async {
    final token = _normalizeToken(apiKey);
    if (token.isEmpty) throw ArgumentError('Fish-Audio-Key fehlt');
    if (pcm16.isEmpty) return const FishAsrTranscript(text: '', language: null);
    final request = http.MultipartRequest('POST', Uri.parse(endpoint))
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(http.MultipartFile.fromBytes(
        'audio',
        _wav(pcm16, sampleRate),
        filename: 'snail-utterance.wav',
      ));
    if (language != null && language.trim().isNotEmpty) {
      request.fields['language'] = language.trim();
    }
    // Timestamp alignment adds latency for short utterances and is not used
    // by the live translation path.
    request.fields['ignore_timestamps'] = 'true';
    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) {
        throw Exception(
            'Fish-Audio-Key ungültig oder abgelaufen (401). Bitte den Key im Settings-Panel neu speichern.');
      }
      throw Exception('Fish Audio ASR error ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return FishAsrTranscript(
        text: (decoded['text'] ?? decoded['transcript'] ?? '').toString().trim(),
        language: (decoded['language'] ??
                decoded['language_code'] ??
                decoded['detected_language'])
            ?.toString()
            .trim()
            .toLowerCase(),
      );
    }
    return const FishAsrTranscript(text: '', language: null);
  }

  String _normalizeToken(String value) {
    var token = value.trim();
    if (token.toLowerCase().startsWith('bearer ')) {
      token = token.substring(7).trim();
    }
    return token;
  }

  Uint8List _wav(Uint8List pcm, int sampleRate) {
    final rate = sampleRate > 0 ? sampleRate : 16000;
    final bytesPerSecond = rate * 2;
    final out = ByteData(44 + pcm.length);
    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        out.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    out.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little);
    out.setUint16(22, 1, Endian.little);
    out.setUint32(24, rate, Endian.little);
    out.setUint32(28, bytesPerSecond, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    out.setUint32(40, pcm.length, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      out.setUint8(44 + i, pcm[i]);
    }
    return out.buffer.asUint8List();
  }
}

class FishAsrTranscript {
  final String text;
  final String? language;

  const FishAsrTranscript({required this.text, required this.language});
}
