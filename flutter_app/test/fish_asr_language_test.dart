import 'package:flutter_test/flutter_test.dart';

import 'package:snail/services/fish_audio_asr_service.dart';

void main() {
  group('FishAudioAsrService.normalizeLanguage', () {
    test('passes through plain two-letter codes', () {
      expect(FishAudioAsrService.normalizeLanguage('de'), 'de');
      expect(FishAudioAsrService.normalizeLanguage(' EN '), 'en');
    });

    test('strips regional tags so the code stays comparable', () {
      // 'de-DE' has to reduce to 'de'. Otherwise it never compares equal to
      // the session target language and it produces an invalid MyMemory
      // langpair, so the turn silently ends up untranslated.
      expect(FishAudioAsrService.normalizeLanguage('de-DE'), 'de');
      expect(FishAudioAsrService.normalizeLanguage('en_US'), 'en');
      expect(FishAudioAsrService.normalizeLanguage('zh-Hans'), 'zh');
    });

    test('maps English language names', () {
      expect(FishAudioAsrService.normalizeLanguage('German'), 'de');
      expect(FishAudioAsrService.normalizeLanguage('english'), 'en');
      expect(FishAudioAsrService.normalizeLanguage('Ukrainian'), 'uk');
    });

    test('treats missing and placeholder values as unknown', () {
      expect(FishAudioAsrService.normalizeLanguage(null), isNull);
      expect(FishAudioAsrService.normalizeLanguage(''), isNull);
      expect(FishAudioAsrService.normalizeLanguage('  '), isNull);
      expect(FishAudioAsrService.normalizeLanguage('auto'), isNull);
      expect(FishAudioAsrService.normalizeLanguage('unknown'), isNull);
    });
  });
}
