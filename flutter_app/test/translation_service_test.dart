import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:snail/models/provider_config.dart';
import 'package:snail/services/translation_service.dart';

ProviderConfig _fishConfig() => const ProviderConfig(
      provider: TranslationProvider.fishAudio,
      endpoint: 'https://api.fish.audio',
      model: 's2-pro',
      apiKey: 'test-key',
    );

/// A client where the local Ollama default (127.0.0.1:11434) is unreachable,
/// which is what actually happens on a phone, and MyMemory answers with
/// [myMemoryBody] and [myMemoryStatus].
MockClient _client(String myMemoryBody, {int myMemoryStatus = 200}) {
  return MockClient((request) async {
    if (request.url.host == 'api.mymemory.translated.net') {
      return http.Response(myMemoryBody, myMemoryStatus,
          headers: {'content-type': 'application/json'});
    }
    throw http.ClientException('connection refused');
  });
}

void main() {
  group('translation is never silently skipped', () {
    test('identical languages report failure instead of echoing the input',
        () async {
      final service = TranslationService(client: _client('{}'));
      final result = await service.translate(
        text: 'Guten Morgen, dies ist ein vollständiger Übersetzungstest.',
        sourceLang: 'de',
        targetLang: 'de',
        config: _fishConfig(),
      );

      // The old code returned the input here, and the caller handed it to TTS
      // — the app spoke the user's own sentence back in their own language.
      expect(result.translated, isFalse);
      expect(result.reason, contains('identisch'));
      expect(result.text, startsWith('Guten Morgen'));
    });

    test('empty input is reported, not translated', () async {
      final service = TranslationService(client: _client('{}'));
      final result = await service.translate(
        text: '   ',
        sourceLang: 'de',
        targetLang: 'en',
        config: _fishConfig(),
      );
      expect(result.translated, isFalse);
    });

    test('a real translation is reported as translated', () async {
      final service = TranslationService(client: _client(jsonEncode({
        'responseData': {'translatedText': 'Good morning'},
        'responseStatus': 200,
      })));
      final result = await service.translate(
        text: 'Guten Morgen',
        sourceLang: 'de',
        targetLang: 'en',
        config: _fishConfig(),
      );
      expect(result.translated, isTrue);
      expect(result.text, 'Good morning');
    });
  });

  group('MyMemory refusals are not treated as translations', () {
    // Verified against the live API: an unsupported pair answers HTTP 200 with
    // responseStatus 403 and puts an English instruction in translatedText.
    const refusal = {
      'responseData': {'translatedText': 'PLEASE SELECT TWO DISTINCT LANGUAGES'},
      'responseStatus': '403',
      'responseDetails': 'PLEASE SELECT TWO DISTINCT LANGUAGES',
    };

    test('a 403 inside an HTTP 200 body is rejected', () async {
      final service = TranslationService(client: _client(jsonEncode(refusal)));
      final result = await service.translate(
        text: 'Guten Morgen',
        sourceLang: 'de',
        targetLang: 'en',
        config: _fishConfig(),
      );

      expect(result.translated, isFalse,
          reason: 'the refusal sentence would otherwise be spoken by TTS');
      expect(result.text, isNot(contains('PLEASE SELECT')));
      expect(result.reason, contains('403'));
    });

    test('numeric responseStatus 403 is rejected too', () async {
      final service = TranslationService(
          client: _client(jsonEncode({...refusal, 'responseStatus': 403})));
      final result = await service.translate(
        text: 'Guten Morgen',
        sourceLang: 'de',
        targetLang: 'en',
        config: _fishConfig(),
      );
      expect(result.translated, isFalse);
    });

    test('an HTTP error from MyMemory is reported', () async {
      final service =
          TranslationService(client: _client('rate limited', myMemoryStatus: 429));
      final result = await service.translate(
        text: 'Guten Morgen',
        sourceLang: 'de',
        targetLang: 'en',
        config: _fishConfig(),
      );
      expect(result.translated, isFalse);
      expect(result.reason, contains('429'));
    });

    test('the unreachable local Ollama default is named in the reason',
        () async {
      final service = TranslationService(client: _client('nope', myMemoryStatus: 500));
      final result = await service.translate(
        text: 'Guten Morgen',
        sourceLang: 'de',
        targetLang: 'en',
        config: _fishConfig(),
      );
      // The shipped Fish default points at an Ollama on the phone itself,
      // so the primary call can never succeed there.
      expect(result.translated, isFalse);
      expect(result.reason, contains('127.0.0.1:11434'));
    });
  });
}
