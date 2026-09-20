import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/fish_audio_asr_service.dart';

/// The ASR hallucination guard: Fish ASR invents text (observed on-device:
/// Chinese lyrics during a German/English conversation) when it receives
/// echo, noise or silence. The guard must reject wrong-script inventions
/// without touching legitimate transcripts.
void main() {
  group('isImplausibleTranscript', () {
    test('accepts a German transcript for a German turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript(
            'Guten Tag, wie geht es dir?', 'de'),
        isFalse,
      );
    });

    test('accepts an English transcript for an English turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript(
            'Hello, how are you doing today?', 'en'),
        isFalse,
      );
    });

    test('rejects Chinese hallucination for a German turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript('真是的。', 'de'),
        isTrue,
      );
      expect(
        FishAudioAsrService.isImplausibleTranscript(
            '《大鱼》是周杰伦演唱的一首歌曲', 'en'),
        isTrue,
      );
    });

    test('rejects Cyrillic for a German turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript('Привет, как дела', 'de'),
        isTrue,
      );
    });

    test('accepts Cyrillic for a Russian turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript('Привет, как дела', 'ru'),
        isFalse,
      );
    });

    test('accepts Chinese for a Chinese turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript('你好，今天怎么样？', 'zh'),
        isFalse,
      );
    });

    test('rejects empty and punctuation-only output', () {
      expect(FishAudioAsrService.isImplausibleTranscript('', 'de'), isTrue);
      expect(FishAudioAsrService.isImplausibleTranscript('   ', 'de'), isTrue);
      expect(FishAudioAsrService.isImplausibleTranscript('...', 'de'), isTrue);
      expect(FishAudioAsrService.isImplausibleTranscript('♪♪', 'de'), isTrue);
    });

    test('accepts digits-only output as a plausible turn', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript('123 456', 'de'),
        isFalse,
      );
    });

    test('accepts mixed Latin + CJK for a CJK language', () {
      expect(
        FishAudioAsrService.isImplausibleTranscript('OK 好的', 'zh'),
        isFalse,
      );
    });
  });

  /// The script guard cannot see an invention written in the same alphabet as
  /// the expected language. On a real two-device run Fish ASR produced Czech
  /// sentences from background noise in a German conversation, and the whole
  /// audience saw them. Fish reports a detected language per transcript, so
  /// that is what decides these.
  group('isWrongDetectedLanguage', () {
    test('rejects a Czech detection for a German turn', () {
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('cs', 'de'),
        isTrue,
      );
    });

    test('accepts a matching detection', () {
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('de', 'de'),
        isFalse,
      );
    });

    test('accepts a regional tag for the same language', () {
      // Fish may answer "de-DE"; the normalizer reduces it to "de".
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('de-DE', 'de'),
        isFalse,
      );
    });

    test('accepts an English language name for the same language', () {
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('German', 'de'),
        isFalse,
      );
    });

    test('accepts a missing detection', () {
      // Fish omits the field for short clips; rejecting those would drop real
      // speech.
      expect(
        FishAudioAsrService.isWrongDetectedLanguage(null, 'de'),
        isFalse,
      );
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('auto', 'de'),
        isFalse,
      );
    });

    test('accepts any detection when the expected language is unknown', () {
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('cs', 'auto'),
        isFalse,
      );
    });

    test('rejects a Latin-script mismatch the script guard would miss', () {
      // The exact case from the hardware run: Czech text, German expectation.
      const invented = 'šápy třeba jsou zemným výrobem';
      expect(
        FishAudioAsrService.isImplausibleTranscript(invented, 'de'),
        isFalse,
        reason: 'the script guard cannot see this — both are Latin',
      );
      expect(
        FishAudioAsrService.isWrongDetectedLanguage('cs', 'de'),
        isTrue,
        reason: 'the language check catches it',
      );
    });
  });
}
