import '../models/provider_config.dart';
import 'translation_service.dart';

/// Turns one ASR transcript into per-language subtitles.
///
/// Extracted from the guide screen so the routing rules can be tested without
/// a widget tree, a microphone or a provider: which languages are translated,
/// which transcripts are rejected, and which results reach the audience.
class GuidePipeline {
  GuidePipeline({
    required this.translate,
    required this.publish,
    required this.isImplausible,
    required this.isWrongLanguage,
  });

  /// Translation backend. Injected so tests can supply a fake.
  final Future<TranslationResult> Function({
    required String text,
    required String sourceLang,
    required String targetLang,
    required ProviderConfig config,
  }) translate;

  /// Delivers one finished subtitle to the relay.
  final void Function({
    required String text,
    required String sourceLang,
    required String targetLang,
  }) publish;

  /// Rejects a transcript that cannot belong to [expectedLanguage] — the Fish
  /// ASR hallucination guard. Injected so the pipeline stays testable.
  final bool Function(String text, String expectedLanguage) isImplausible;

  /// Rejects a transcript whose *detected language* contradicts
  /// [expectedLanguage]. Catches Latin-script inventions that the script-based
  /// guard cannot see.
  final bool Function(String? detectedLanguage, String expectedLanguage)
      isWrongLanguage;

  /// Processes one completed turn.
  ///
  /// Returns the subtitles that were published, in target-language order.
  /// The guide's own language is skipped: listeners who speak it read the
  /// original, and translating a language into itself is a provider error.
  Future<List<PublishedSubtitle>> processTurn({
    required String source,
    required String sourceLang,
    required List<String> listenerLanguages,
    required ProviderConfig config,
    String? detectedLanguage,
  }) async {
    final text = source.trim();
    if (text.isEmpty) return const <PublishedSubtitle>[];
    // A wrong-language invention would be translated into every listener
    // language and shown to the whole audience, so it is dropped before any
    // translation call is made.
    if (isImplausible(text, sourceLang)) return const <PublishedSubtitle>[];
    // The script guard cannot see an invention written in the same alphabet,
    // so the provider's own language detection decides those.
    if (isWrongLanguage(detectedLanguage, sourceLang)) {
      return const <PublishedSubtitle>[];
    }

    final targets = listenerLanguages
        .where((lang) => lang != sourceLang)
        .toList(growable: false);
    if (targets.isEmpty) return const <PublishedSubtitle>[];

    // One translation per target language, in parallel: a slow language must
    // not delay the others.
    final results = await Future.wait(targets.map((target) async {
      final result = await translate(
        text: text,
        sourceLang: sourceLang,
        targetLang: target,
        config: config,
      );
      return MapEntry(target, result);
    }));

    final published = <PublishedSubtitle>[];
    for (final entry in results) {
      final result = entry.value;
      // Never publish the source text back: it reads like a working
      // translation while nothing was translated at all.
      if (!result.translated) continue;
      publish(
        text: result.text,
        sourceLang: sourceLang,
        targetLang: entry.key,
      );
      published.add(PublishedSubtitle(
        text: result.text,
        sourceLang: sourceLang,
        targetLang: entry.key,
      ));
    }
    return published;
  }
}

/// One subtitle that reached the audience.
class PublishedSubtitle {
  const PublishedSubtitle({
    required this.text,
    required this.sourceLang,
    required this.targetLang,
  });

  final String text;
  final String sourceLang;
  final String targetLang;
}
