import 'dart:typed_data';

/// Client-side audio processing: PCM resampling and S16LE conversion.
///
/// Based on Viva Translate's AudioWorkletProcessor pattern.
class AudioProcessor {
  /// Resample audio from [inRate] to [outRate] using linear interpolation.
  static Float32List resample(Float32List input, int inRate, int outRate) {
    if (input.isEmpty) return Float32List(0);
    if (inRate <= 0 || outRate <= 0) return Float32List.fromList(input);
    if (input.length == 1) return Float32List.fromList(input);
    final outCount = (input.length * outRate / inRate).round();
    if (outCount <= 1) return Float32List.fromList([input[0]]);
    final outData = Float32List(outCount);
    final factor = (input.length - 1) / (outCount - 1);
    outData[0] = input[0];
    for (int i = 1; i < outCount - 1; i++) {
      final j = i * factor;
      final floor = j.floor();
      final frac = j - floor;
      outData[i] = input[floor] * (1 - frac) + input[floor + 1] * frac;
    }
    outData[outCount - 1] = input[input.length - 1];
    return outData;
  }

  /// Convert Float32 samples to S16LE (Signed 16-bit Little Endian).
  static Int16List toS16LE(Float32List samples) {
    final frame = Int16List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i].clamp(-1.0, 1.0);
      frame[i] = (s < 0 ? s * 0x8000 : s * 0x7FFF).round();
    }
    return frame;
  }

  /// Process raw PCM bytes: convert to Float32, resample, convert to S16LE.
  ///
  /// [rawPcm] — raw 16-bit PCM bytes at [inRate] Hz.
  /// Returns S16LE bytes at [outRate] Hz.
  static Uint8List processAudioChunk(
      Uint8List rawPcm, int inRate, int outRate) {
    // Convert bytes to Float32
    final int16 =
        Int16List.view(rawPcm.buffer, rawPcm.offsetInBytes, rawPcm.length ~/ 2);
    final float32 = Float32List(int16.length);
    for (int i = 0; i < int16.length; i++) {
      float32[i] = int16[i] / 32768.0;
    }

    // Resample
    final resampled = resample(float32, inRate, outRate);

    // Convert to S16LE
    final s16le = toS16LE(resampled);

    return s16le.buffer.asUint8List();
  }
}
