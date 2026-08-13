import 'dart:math' as math;
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
    final byteData = ByteData.sublistView(rawPcm);
    final sampleCount = rawPcm.length ~/ 2;
    final float32 = Float32List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      float32[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }

    // Resample
    final resampled = resample(float32, inRate, outRate);

    // Convert to S16LE
    final s16le = toS16LE(resampled);

    return s16le.buffer.asUint8List();
  }

  /// Compute the RMS (root mean square) level of raw 16-bit PCM audio.
  ///
  /// Returns a value between 0.0 (silence) and 1.0 (clipping). The square root
  /// is required: without it the result is the mean square, which reads about
  /// an order of magnitude too low for speech (a -22 dBFS sentence measures
  /// 0.076 RMS but only 0.0058 mean square) and makes every threshold and
  /// meter built on top of it wrong.
  static double computeLevel(Uint8List rawPcm) {
    if (rawPcm.length < 2) return 0.0;
    final byteData = ByteData.sublistView(rawPcm);
    final sampleCount = rawPcm.length ~/ 2;
    var sumSquares = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }
    return math.sqrt(sumSquares / sampleCount).clamp(0.0, 1.0);
  }

  /// Convert a normalized RMS level (see [computeLevel]) to dBFS.
  ///
  /// Amplitude ratios use 20·log10, not the natural logarithm. Returns -120
  /// for digital silence so callers can display a finite floor.
  static double levelToDbfs(double level) {
    if (level <= 0.000001) return -120.0;
    return 20 * (math.log(level) / math.ln10);
  }

  /// Highest absolute sample amplitude as a normalized 0..1 value.
  static double computePeak(Uint8List rawPcm) {
    if (rawPcm.length < 2) return 0.0;
    final data = ByteData.sublistView(rawPcm);
    var peak = 0;
    for (var i = 0; i < rawPcm.length ~/ 2; i++) {
      final value = data.getInt16(i * 2, Endian.little).abs();
      if (value > peak) peak = value;
    }
    return (peak / 32768.0).clamp(0.0, 1.0);
  }

  /// Detect clipping in raw 16-bit PCM audio.
  ///
  /// Returns true if any sample reaches the maximum amplitude (±32767),
  /// indicating the microphone input is too loud.
  static bool detectClipping(Uint8List rawPcm) {
    if (rawPcm.length < 2) return false;
    final byteData = ByteData.sublistView(rawPcm);
    for (var i = 0; i < rawPcm.length ~/ 2; i++) {
      final s = byteData.getInt16(i * 2, Endian.little);
      if (s == 32767 || s == -32768) return true;
    }
    return false;
  }

  /// Detect silence in raw 16-bit PCM audio.
  ///
  /// Returns true if the RMS level is below [threshold]. The default
  /// threshold of 0.01 corresponds to approximately -40 dBFS, which is
  /// quiet enough to be considered silence in most environments.
  static bool detectSilence(Uint8List rawPcm, {double threshold = 0.01}) {
    return computeLevel(rawPcm) < threshold;
  }
}
