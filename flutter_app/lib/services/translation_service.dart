import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/provider_config.dart';

class TranslationService {
  Future<String> translate(
      {required String text,
      required String sourceLang,
      required String targetLang,
      required ProviderConfig config}) async {
    if (sourceLang == targetLang || text.trim().isEmpty) return text;
    final prompt =
        'Translate from $sourceLang to $targetLang. Return only the translation, no explanation:\n$text';
    if (config.provider == TranslationProvider.ollama) {
      final response = await http.post(
        Uri.parse(
            '${config.endpoint.replaceFirst(RegExp(r'/$'), '')}/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': config.model,
          'stream': false,
          'messages': [
            {'role': 'user', 'content': prompt}
          ]
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Ollama error ${response.statusCode}');
      }
      return (jsonDecode(response.body)['message']?['content'] as String?)
              ?.trim() ??
          text;
    }

    if (config.provider == TranslationProvider.geminiLive) {
      throw Exception(
          'Gemini Live ist für Chat-Text noch nicht implementiert; für Live-Audio vorgesehen');
    }

    if (config.apiKey.trim().isEmpty) throw Exception('OpenAI-BYOK-Key fehlt');
    final base = config.endpoint.replaceFirst(RegExp(r'/$'), '');
    final isGpt56 = config.chatModel.startsWith('gpt-5.6');
    final response = await http.post(
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
      return output.trim().isEmpty ? text : output.trim();
    }
    return (body['choices']?[0]?['message']?['content'] as String?)?.trim() ??
        text;
  }
}
