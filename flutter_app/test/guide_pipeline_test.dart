import 'package:flutter_test/flutter_test.dart';

import 'package:snail/models/provider_config.dart';
import 'package:snail/services/guide_pipeline.dart';
import 'package:snail/services/translation_service.dart';

const _config = ProviderConfig(
  provider: TranslationProvider.openAi,
  endpoint: 'https://api.openai.com/v1',
  model: 'gpt-5.6-luna',
  apiKey: 'test-key',
);

/// Records every translation request and answers from a script.
class _FakeTranslator {
  _FakeTranslator({this.failing = const <String>{}});

  /// Target languages whose translation should fail.
  final Set<String> failing;
  final List<String> requested = <String>[];

  Future<TranslationResult> call({
    required String text,
    required String sourceLang,
    required String targetLang,
    required ProviderConfig config,
  }) async {
    requested.add(targetLang);
    if (failing.contains(targetLang)) {
      return TranslationResult.failed(text, 'fake_failure');
    }
    return TranslationResult.ok('[$targetLang] $text');
  }
}

void main() {
  group('GuidePipeline', () {
    test('publishes one subtitle per listener language', () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        isWrongLanguage: (_, __) => false,
      );

      final result = await pipeline.processTurn(
        source: 'Guten Tag',
        sourceLang: 'de',
        listenerLanguages: ['en', 'fr', 'es'],
        config: _config,
      );

      expect(result, hasLength(3));
      expect(published.map((entry) => entry.targetLang), ['en', 'fr', 'es']);
      expect(published.first.text, '[en] Guten Tag');
      expect(published.first.sourceLang, 'de');
    });

    test('skips the guide language instead of translating into itself',
        () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        isWrongLanguage: (_, __) => false,
      );

      await pipeline.processTurn(
        source: 'Guten Tag',
        sourceLang: 'de',
        listenerLanguages: ['de', 'en'],
        config: _config,
      );

      // Translating German into German is a provider error, and a listener
      // who speaks the guide's language reads the original.
      expect(translator.requested, ['en']);
      expect(published.map((entry) => entry.targetLang), ['en']);
    });

    test('drops an implausible transcript before any translation call',
        () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        // The Fish ASR hallucination guard: a Chinese lyric in a German
        // conversation must never reach the audience.
        isImplausible: (text, expected) => text.contains('大鱼'),
        isWrongLanguage: (_, __) => false,
      );

      final result = await pipeline.processTurn(
        source: '大鱼海棠',
        sourceLang: 'de',
        listenerLanguages: ['en'],
        config: _config,
      );

      expect(result, isEmpty);
      expect(published, isEmpty);
      // Not a single provider call was made for the invention.
      expect(translator.requested, isEmpty);
    });

    test('never publishes the source text when a translation fails', () async {
      final translator = _FakeTranslator(failing: {'fr'});
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        isWrongLanguage: (_, __) => false,
      );

      await pipeline.processTurn(
        source: 'Guten Tag',
        sourceLang: 'de',
        listenerLanguages: ['en', 'fr'],
        config: _config,
      );

      // English succeeded, French failed — the failure is silent, not a
      // German sentence shown to French listeners as if it were French.
      expect(published.map((entry) => entry.targetLang), ['en']);
    });

    test('ignores empty transcripts and rooms without target languages',
        () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        isWrongLanguage: (_, __) => false,
      );

      expect(
        await pipeline.processTurn(
            source: '   ',
            sourceLang: 'de',
            listenerLanguages: ['en'],
            config: _config),
        isEmpty,
      );
      expect(
        await pipeline.processTurn(
            source: 'Hallo',
            sourceLang: 'de',
            listenerLanguages: ['de'],
            config: _config),
        isEmpty,
      );
      expect(translator.requested, isEmpty);
      expect(published, isEmpty);
    });

    test('translates every target in parallel, not one after another',
        () async {
      final translator = _FakeTranslator();
      final pipeline = GuidePipeline(
        translate: ({required text, required sourceLang, required targetLang, required config}) async {
          // Each language takes 50 ms; three in parallel finish in ~50 ms,
          // sequentially they would need 150 ms.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return TranslationResult.ok('[$targetLang] $text');
        },
        publish: ({required text, required sourceLang, required targetLang}) {},
        isImplausible: (_, __) => false,
        isWrongLanguage: (_, __) => false,
      );

      final watch = Stopwatch()..start();
      await pipeline.processTurn(
        source: 'Guten Tag',
        sourceLang: 'de',
        listenerLanguages: ['en', 'fr', 'es'],
        config: _config,
      );
      watch.stop();

      expect(translator.requested, hasLength(0));
      expect(watch.elapsedMilliseconds, lessThan(140));
    });

    test('drops a turn whose detected language contradicts the source',
        () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        // The script guard cannot see this: Czech and German share the Latin
        // alphabet, so only the provider's detection catches it.
        isWrongLanguage: (detected, expected) =>
            detected != null && detected != expected,
      );

      final result = await pipeline.processTurn(
        source: 'šápy třeba jsou zemným výrobem',
        sourceLang: 'de',
        listenerLanguages: ['en'],
        config: _config,
        detectedLanguage: 'cs',
      );

      expect(result, isEmpty);
      expect(published, isEmpty);
      // No provider call was made for the invention.
      expect(translator.requested, isEmpty);
    });

    test('accepts a turn when the provider omits the detected language',
        () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        // Fish omits the field for short clips; rejecting those would drop
        // real speech.
        isWrongLanguage: (detected, expected) =>
            detected != null && detected != expected,
      );

      final result = await pipeline.processTurn(
        source: 'Guten Tag',
        sourceLang: 'de',
        listenerLanguages: ['en'],
        config: _config,
        detectedLanguage: null,
      );

      expect(result, hasLength(1));
      expect(published.single.targetLang, 'en');
    });

    test('accepts a turn whose detected language matches the source',
        () async {
      final translator = _FakeTranslator();
      final published = <PublishedSubtitle>[];
      final pipeline = GuidePipeline(
        translate: translator.call,
        publish: ({required text, required sourceLang, required targetLang}) =>
            published.add(PublishedSubtitle(
                text: text, sourceLang: sourceLang, targetLang: targetLang)),
        isImplausible: (_, __) => false,
        isWrongLanguage: (detected, expected) =>
            detected != null && detected != expected,
      );

      final result = await pipeline.processTurn(
        source: 'Guten Tag',
        sourceLang: 'de',
        listenerLanguages: ['en'],
        config: _config,
        detectedLanguage: 'de',
      );

      expect(result, hasLength(1));
    });
  });
}
