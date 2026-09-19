import 'package:flutter_test/flutter_test.dart';

import 'package:snail/services/tts_queue_policy.dart';

/// Records what the engine was asked to do.
class _FakeTts {
  final List<String> spoken = <String>[];
  int stops = 0;

  Future<void> speak(String text) async {
    spoken.add(text);
  }

  Future<void> stop() async {
    stops++;
  }
}

void main() {
  group('TtsQueuePolicy sentence detection', () {
    test('accepts complete sentences in every supported script', () {
      expect(TtsQueuePolicy.isCompleteSentence('Guten Tag.'), isTrue);
      expect(TtsQueuePolicy.isCompleteSentence('How are you?'), isTrue);
      expect(TtsQueuePolicy.isCompleteSentence('Bonjour!'), isTrue);
      expect(TtsQueuePolicy.isCompleteSentence('你好。'), isTrue);
      expect(TtsQueuePolicy.isCompleteSentence('こんにちは！'), isTrue);
      expect(TtsQueuePolicy.isCompleteSentence('Привет…'), isTrue);
    });

    test('rejects partial turns and fragments', () {
      // A streaming ASR emits these constantly; speaking them stutters and
      // then repeats the same words once the full sentence arrives.
      expect(TtsQueuePolicy.isCompleteSentence('Guten Ta'), isFalse);
      expect(TtsQueuePolicy.isCompleteSentence('und dann'), isFalse);
      expect(TtsQueuePolicy.isCompleteSentence(''), isFalse);
      expect(TtsQueuePolicy.isCompleteSentence('.'), isFalse);
      expect(TtsQueuePolicy.isCompleteSentence('   '), isFalse);
    });
  });

  group('TtsQueuePolicy queue discipline', () {
    test('speaks a complete sentence and ignores fragments', () async {
      final tts = _FakeTts();
      final policy = TtsQueuePolicy(speak: tts.speak, stop: tts.stop);

      expect(await policy.offer('Guten Ta', enabled: true), isFalse);
      expect(await policy.offer('Guten Tag.', enabled: true), isTrue);

      expect(tts.spoken, ['Guten Tag.']);
      expect(tts.stops, 0);
    });

    test('stays silent when read-aloud is disabled', () async {
      final tts = _FakeTts();
      final policy = TtsQueuePolicy(speak: tts.speak, stop: tts.stop);

      expect(await policy.offer('Guten Tag.', enabled: false), isFalse);
      expect(tts.spoken, isEmpty);
    });

    test('drops the queue when it falls behind instead of reading stale lines',
        () async {
      final tts = _FakeTts();
      final policy = TtsQueuePolicy(
        speak: tts.speak,
        stop: tts.stop,
        maxPending: 2,
      );

      // Three sentences arrive while the engine is still busy: the third
      // offer must clear the backlog rather than queue behind it.
      final pending = <Future<bool>>[
        policy.offer('Erster Satz.', enabled: true),
        policy.offer('Zweiter Satz.', enabled: true),
        policy.offer('Dritter Satz.', enabled: true),
      ];
      await Future.wait(pending);

      expect(tts.stops, greaterThanOrEqualTo(1));
      expect(tts.spoken, contains('Dritter Satz.'));
    });

    test('does not drop the queue while it is keeping up', () async {
      final tts = _FakeTts();
      final policy = TtsQueuePolicy(
        speak: tts.speak,
        stop: tts.stop,
        maxPending: 2,
      );

      await policy.offer('Erster Satz.', enabled: true);
      await policy.offer('Zweiter Satz.', enabled: true);

      expect(tts.stops, 0);
      expect(tts.spoken, ['Erster Satz.', 'Zweiter Satz.']);
    });

    test('releases the pending slot when the engine throws', () async {
      var calls = 0;
      final policy = TtsQueuePolicy(
        speak: (_) async {
          calls++;
          throw StateError('engine gone');
        },
        stop: () async {},
        maxPending: 2,
      );

      await expectLater(
        policy.offer('Erster Satz.', enabled: true),
        throwsA(isA<StateError>()),
      );
      // The slot must not stay occupied, or every later sentence would look
      // like a backlog and trigger a pointless stop().
      expect(policy.pending, 0);
      expect(calls, 1);
    });
  });
}
