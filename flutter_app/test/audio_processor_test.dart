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
}
