import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:snail/services/audio_processor.dart';

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
      final silence = Int16List(100); // all zeros
      expect(
        AudioProcessor.computeLevel(silence.buffer.asUint8List()),
        0.0,
      );
    });

    test('returns ~1.0 for full-scale input', () {
      final fullScale = Int16List(100);
      for (var i = 0; i < 100; i++) {
        fullScale[i] = 32767;
      }
      final level = AudioProcessor.computeLevel(
        fullScale.buffer.asUint8List(),
      );
      expect(level, closeTo(1.0, 0.01));
    });
  });

  group('detectClipping', () {
    test('returns false for empty input', () {
      expect(AudioProcessor.detectClipping(Uint8List(0)), isFalse);
    });

    test('returns false for normal audio', () {
      final normal = Int16List(100);
      for (var i = 0; i < 100; i++) {
        normal[i] = 16000; // well below max
      }
      expect(
        AudioProcessor.detectClipping(normal.buffer.asUint8List()),
        isFalse,
      );
    });

    test('returns true when sample reaches 32767', () {
      final clipping = Int16List(100);
      clipping[50] = 32767; // one clipped sample
      expect(
        AudioProcessor.detectClipping(clipping.buffer.asUint8List()),
        isTrue,
      );
    });

    test('returns true when sample reaches -32768', () {
      final clipping = Int16List(100);
      clipping[50] = -32768; // one clipped sample
      expect(
        AudioProcessor.detectClipping(clipping.buffer.asUint8List()),
        isTrue,
      );
    });
  });
}
