import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/provider_config.dart';

/// Outcome of a translation attempt.
///
/// Whether a translation actually happened must be visible to the caller. The
/// audio pipeline used to receive the untranslated source text on every
/// failure path, hand it to TTS, and speak the user's own sentence back at
/// them in their own language — indistinguishable from a working translation
/// unless you understand both languages, and with no error anywhere.
class TranslationResult {
  const TranslationResult._(this.text, this.translated, this.reason);

  /// Text produced. Equals the input when [translated] is false.
  final String text;

  /// True only when a translation engine actually returned a translation.
  final bool translated;

  /// Why no translation happened. Null when [translated] is true.
  final String? reason;

  const TranslationResult.ok(String text) : this._(text, true, null);

  const TranslationResult.failed(String text, String reason)
      : this._(text, false, reason);
}

class TranslationService {
  TranslationService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<TranslationResult> translate(
      {required String text,
      required String sourceLang,
      required String targetLang,
      required ProviderConfig config}) async {
    if (text.trim().isEmpty) {
      return const TranslationResult.failed('', 'leerer Text');
    }
    if (sourceLang == targetLang) {
      return TranslationResult.failed(
          text, 'Quell- und Zielsprache sind identisch ($sourceLang)');
    }
    final prompt =
        'Translate from $sourceLang to $targetLang. Return only the translation, no explanation:\n$text';
    if (config.provider == TranslationProvider.ollama ||
        config.provider == TranslationProvider.fishAudio) {
      final endpoint = config.provider == TranslationProvider.fishAudio
          ? config.translationEndpoint
          : config.endpoint;
      final model = config.provider == TranslationProvider.fishAudio
          ? config.translationModel
          : config.model;
      var primaryError = 'Übersetzungsdienst nicht erreichbar';
      try {
        final response = await _client.post(
          Uri.parse('${endpoint.replaceFirst(RegExp(r'/$'), '')}/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'stream': false,
            'messages': [
              {'role': 'user', 'content': prompt}
            ]
          }),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final content =
              (jsonDecode(response.body)['message']?['content'] as String?)
                  ?.trim();
          if (content != null && content.isNotEmpty) {
            return TranslationResult.ok(content);
          }
          primaryError = '$endpoint lieferte eine leere Übersetzung';
        } else {
          primaryError = '$endpoint antwortete mit ${response.statusCode}';
        }
      } catch (error) {
        // Fish's mobile default must not silently depend on Ollama on the
        // same phone. Continue with the public low-cost translation fallback.
        primaryError = '$endpoint nicht erreichbar';
      }
      if (config.provider == TranslationProvider.fishAudio) {
        try {
          final fallback =
              await _client.get(Uri.https('api.mymemory.translated.net', '/get', {
            'q': text,
            'langpair': '$sourceLang|$targetLang',
          }));
          if (fallback.statusCode >= 200 && fallback.statusCode < 300) {
            final body = jsonDecode(fallback.body) as Map<String, dynamic>;
            // MyMemory answers HTTP 200 even when it refuses the request and
            // puts the real code in responseStatus (as a string or a number).
            // An unsupported pair comes back as the literal sentence
            // "PLEASE SELECT TWO DISTINCT LANGUAGES", which would otherwise be
            // handed straight to TTS and spoken out loud.
            final status = body['responseStatus'];
            final accepted = status == 200 || status == '200';
            final translated =
                (body['responseData']?['translatedText'] as String?)?.trim();
            if (accepted && translated != null && translated.isNotEmpty) {
              return TranslationResult.ok(translated);
            }
            return TranslationResult.failed(
                text,
                'MyMemory lehnte $sourceLang→$targetLang ab'
                '${status == null ? '' : ' ($status)'}; $primaryError');
          }
          return TranslationResult.failed(
              text,
              'MyMemory antwortete mit ${fallback.statusCode}; '
              '$primaryError');
        } catch (error) {
          return TranslationResult.failed(
              text, 'MyMemory nicht erreichbar; $primaryError');
        }
      }
      return TranslationResult.failed(text, primaryError);
    }

    if (config.provider == TranslationProvider.geminiLive) {
      throw Exception(
          'Gemini Live ist für Chat-Text noch nicht implementiert; für Live-Audio vorgesehen');
    }

    if (config.apiKey.trim().isEmpty) throw Exception('OpenAI-BYOK-Key fehlt');
    final base = config.endpoint.replaceFirst(RegExp(r'/$'), '');
    final isGpt56 = config.chatModel.startsWith('gpt-5.6');
    final response = await _client.post(
      Uri.parse(isGpt56 ? '$base/responses' : '$base/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}'
      },
      body: jsonEncode(isGpt56
          ? {
              'model': config.chatModel,
              'input': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'input_text', 'text': prompt}
                  ]
                }
              ]
            }
          : {
              'model': config.chatModel,
              'temperature': 0,
              'messages': [
                {'role': 'user', 'content': prompt}
              ]
            }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('OpenAI error ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (isGpt56) {
      final output = (body['output'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .expand((item) => (item['content'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>())
          .map((item) => item['text'])
          .whereType<String>()
          .join();
      return output.trim().isEmpty
          ? TranslationResult.failed(text, 'OpenAI lieferte eine leere Antwort')
          : TranslationResult.ok(output.trim());
    }
    final content =
        (body['choices']?[0]?['message']?['content'] as String?)?.trim();
    return content == null || content.isEmpty
        ? TranslationResult.failed(text, 'OpenAI lieferte eine leere Antwort')
        : TranslationResult.ok(content);
  }
}
