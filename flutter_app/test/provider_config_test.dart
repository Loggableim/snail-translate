import 'package:flutter_test/flutter_test.dart';
import 'package:snail/models/provider_config.dart';

void main() {
  test('Fish Audio is a distinct provider with persisted engine settings', () {
    const original = ProviderConfig(
      provider: TranslationProvider.fishAudio,
      endpoint: 'wss://api.fish.audio/v1/tts/live',
      model: 's2.1-pro-free',
      voiceId: '2d4039641d67419fa132ca59fa2f61ad',
      latencyMode: 'balanced',
      translationEndpoint: 'http://127.0.0.1:11434',
      translationModel: 'llama3.2:3b',
    );

    final restored = ProviderConfig.fromJson(original.toJson());

    expect(restored.provider, TranslationProvider.fishAudio);
    expect(restored.endpoint, 'wss://api.fish.audio/v1/tts/live');
    expect(restored.model, 's2.1-pro-free');
    expect(restored.voiceId, '2d4039641d67419fa132ca59fa2f61ad');
    expect(restored.translationModel, 'llama3.2:3b');
    expect(TranslationProvider.fishAudio.displayName, 'Fish Audio');
  });
}
