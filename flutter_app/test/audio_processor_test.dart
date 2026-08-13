import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:snail/services/audio_policy.dart';
import 'package:snail/services/audio_processor.dart';

/// Helper: create a Uint8List from an Int16List with exact byte length.
Uint8List _pcm16(Int16List samples) {
  return Uint8List.fromList(
    samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes),
  );
}

void main() {
  test('resampler tolerates empty and single-sample frames', () {
    expect(AudioProcessor.resample(Float32List(0), 16000, 24000), isEmpty);
    expect(
      AudioProcessor.resample(Float32List.fromList([0.25]), 16000, 24000),
      [0.25],
    );
  });

  test('resampler returns stable data for invalid rates', () {
    final input = Float32List.fromList([-.5, 0, .5]);
    expect(AudioProcessor.resample(input, 0, 24000), input);
    expect(AudioProcessor.resample(input, 16000, 0), input);
  });

  group('computeLevel', () {
    test('returns 0.0 for empty input', () {
      expect(AudioProcessor.computeLevel(Uint8List(0)), 0.0);
    });

    test('returns 0.0 for silence', () {
      final silence = Int16List(100);
      expect(AudioProcessor.computeLevel(_pcm16(silence)), 0.0);
    });

    test('returns ~1.0 for full-scale input', () {
      final fullScale = Int16List(100);
      for (var i = 0; i < 100; i++) {
        fullScale[i] = 32767;
      }
      final level = AudioProcessor.computeLevel(_pcm16(fullScale));
      expect(level, closeTo(1.0, 0.01));
    });

    test('is root mean square, not mean square', () {
      // A half-scale square wave has RMS 0.5. Returning the mean square
      // (0.25) reads a full 6 dB low and breaks every threshold above it.
      final half = Int16List(100);
      for (var i = 0; i < 100; i++) {
        half[i] = i.isEven ? 16384 : -16384;
      }
      expect(AudioProcessor.computeLevel(_pcm16(half)), closeTo(0.5, 0.001));
    });

    test('measures conversational speech near -22 dBFS', () {
      // A 400 Hz sine at 0.0761 RMS matches the recorded German samples in
      // audio_samples/. This is the level the noise gate must let through.
      const rms = 0.0761;
      final amplitude = rms * math.sqrt2;
      final speech = Int16List(1600);
      for (var i = 0; i < speech.length; i++) {
        speech[i] =
            (math.sin(2 * math.pi * 400 * i / 16000) * amplitude * 32767)
                .round();
      }
      final level = AudioProcessor.computeLevel(_pcm16(speech));
      expect(level, closeTo(rms, 0.002));
      expect(AudioProcessor.levelToDbfs(level), closeTo(-22.4, 0.3));
      // The shipped default gate must not treat this as silence.
      expect(
        AudioProcessor.detectSilence(_pcm16(speech),
            threshold: AudioPolicy.defaultNoiseGate),
        isFalse,
      );
    });
  });

  group('levelToDbfs', () {
    test('uses the base-10 amplitude decibel scale', () {
      expect(AudioProcessor.levelToDbfs(1.0), closeTo(0.0, 0.001));
      expect(AudioProcessor.levelToDbfs(0.1), closeTo(-20.0, 0.001));
      expect(AudioProcessor.levelToDbfs(0.01), closeTo(-40.0, 0.001));
    });

    test('floors digital silence instead of returning -infinity', () {
      expect(AudioProcessor.levelToDbfs(0.0), -120.0);
    });
  });

  group('detectClipping', () {
    test('returns false for empty input', () {
      expect(AudioProcessor.detectClipping(Uint8List(0)), isFalse);
    });

    test('returns false for normal audio', () {
      final normal = Int16List(100);
      for (var i = 0; i < 100; i++) {
        normal[i] = 16000;
      }
      expect(AudioProcessor.detectClipping(_pcm16(normal)), isFalse);
    });

    test('returns true when sample reaches 32767', () {
      final clipping = Int16List(100);
      clipping[50] = 32767;
      expect(AudioProcessor.detectClipping(_pcm16(clipping)), isTrue);
    });

    test('returns true when sample reaches -32768', () {
      final clipping = Int16List(100);
      clipping[50] = -32768;
      expect(AudioProcessor.detectClipping(_pcm16(clipping)), isTrue);
    });
  });

  group('detectSilence', () {
    test('returns true for empty input', () {
      expect(AudioProcessor.detectSilence(Uint8List(0)), isTrue);
    });

    test('returns true for near-silent audio', () {
      final nearSilent = Int16List(100);
      nearSilent[0] = 1;
      expect(AudioProcessor.detectSilence(_pcm16(nearSilent)), isTrue);
    });

    test('returns false for normal speech-level audio', () {
      final speech = Int16List(100);
      for (var i = 0; i < 100; i++) {
        speech[i] = 8000;
      }
      expect(AudioProcessor.detectSilence(_pcm16(speech)), isFalse);
    });

    test('respects custom threshold', () {
      final moderate = Int16List(100);
      for (var i = 0; i < 100; i++) {
        moderate[i] = 16000;
      }
      // Default threshold (0.01) should detect this as non-silent
      expect(
        AudioProcessor.detectSilence(_pcm16(moderate)),
        isFalse,
      );
      // Higher threshold should detect it as silent
      expect(
        AudioProcessor.detectSilence(
          _pcm16(moderate),
          threshold: 0.9,
        ),
        isTrue,
      );
    });
  });
}
