import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/fish_audio_realtime_service.dart';
import 'package:snail/services/gemini_live_service.dart';
import 'package:snail/services/live_translation_provider.dart';
import 'package:snail/services/openai_realtime_service.dart';

void main() {
  test('all live providers expose the common lifecycle contract', () async {
    final providers = <LiveTranslationProvider>[
      OpenAiRealtimeService(),
      GeminiLiveService(),
      FishAudioRealtimeService(),
    ];

    expect(providers.map((provider) => provider.state),
        everyElement(equals('idle')));
    expect(
        providers.map((provider) => provider.lastError), everyElement(isNull));
    for (final provider in providers) {
      await provider.disconnect();
    }
  });
}
