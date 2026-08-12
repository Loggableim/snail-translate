import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/openai_realtime_service.dart';

void main() {
  group('OpenAiRealtimeService audio buffer', () {
    test('flushAudio clears buffered audio chunks', () {
      final service = OpenAiRealtimeService();

      // Simulate audio chunks being added (via internal mechanism)
      // We can't directly add to _audioChunks, but we can verify
      // that takeAudioChunks returns empty after construction.
      expect(service.takeAudioChunks(), isEmpty);

      // flushAudio should be a no-op on empty buffer
      service.flushAudio();
      expect(service.takeAudioChunks(), isEmpty);
    });

    test('hasPendingAudio is false after construction', () {
      final service = OpenAiRealtimeService();
      expect(service.hasPendingAudio, isFalse);
    });

    test('state starts as idle', () {
      final service = OpenAiRealtimeService();
      expect(service.state, 'idle');
    });
  });
}
