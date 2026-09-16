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
}
