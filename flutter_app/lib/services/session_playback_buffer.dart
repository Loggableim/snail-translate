import 'dart:typed_data';

/// A time-based jitter buffer for received PCM16 session audio.
///
/// It deliberately measures buffered *audio time*, rather than number of
/// packets: provider packet sizes vary and a packet-count prebuffer starts too
/// early when 300-ms chunks arrive one at a time.
class SessionPlaybackBuffer {
  SessionPlaybackBuffer({
    this.baseTargetMs = 750,
    this.lowWaterMs = 350,
    this.maxBufferedMs = 5000,
  });

  final int baseTargetMs;
  final int lowWaterMs;
  final int maxBufferedMs;
  final List<SessionPlaybackChunk> _chunks = <SessionPlaybackChunk>[];

  int _bufferedMs = 0;
  int _droppedChunks = 0;
  int _largestArrivalJitterMs = 0;
  DateTime? _lastArrival;
  int? _lastChunkDurationMs;

  int get bufferedMs => _bufferedMs;
  int get droppedChunks => _droppedChunks;
  int get largestArrivalJitterMs => _largestArrivalJitterMs;
  bool get isEmpty => _chunks.isEmpty;
  int get targetMs => (baseTargetMs + _largestArrivalJitterMs * 2)
      .clamp(baseTargetMs, maxBufferedMs);

  void add(Uint8List bytes, int sampleRate, DateTime now) {
    if (bytes.isEmpty || sampleRate <= 0) return;
    final durationMs = _durationMs(bytes, sampleRate);
    if (_lastArrival != null && _lastChunkDurationMs != null) {
      final arrivalMs = now.difference(_lastArrival!).inMilliseconds;
      final jitterMs = (arrivalMs - _lastChunkDurationMs!).abs();
      if (jitterMs > _largestArrivalJitterMs) {
        _largestArrivalJitterMs = jitterMs;
      }
    }
    _lastArrival = now;
    _lastChunkDurationMs = durationMs;
    _chunks.add(SessionPlaybackChunk(bytes, sampleRate, durationMs));
    _bufferedMs += durationMs;
    while (_bufferedMs > maxBufferedMs && _chunks.isNotEmpty) {
      _bufferedMs -= _chunks.removeAt(0).durationMs;
      _droppedChunks++;
    }
  }

  bool shouldStart({bool force = false}) =>
      _bufferedMs >= targetMs || (force && _bufferedMs > 0);

  /// The player may continue after it starts; a low-water mark is retained as
  /// telemetry for diagnosing runs that are likely to underrun.
  bool get belowLowWater => _bufferedMs > 0 && _bufferedMs < lowWaterMs;

  SessionPlaybackChunk? take() {
    if (_chunks.isEmpty) return null;
    final chunk = _chunks.removeAt(0);
    _bufferedMs -= chunk.durationMs;
    return chunk;
  }

  void clear() {
    _chunks.clear();
    _bufferedMs = 0;
    _lastArrival = null;
    _lastChunkDurationMs = null;
    _largestArrivalJitterMs = 0;
  }

  static int _durationMs(Uint8List bytes, int sampleRate) =>
      ((bytes.length * 1000) / (sampleRate * 2)).ceil().clamp(1, 60000);
}

class SessionPlaybackChunk {
  const SessionPlaybackChunk(this.bytes, this.sampleRate, this.durationMs);

  final Uint8List bytes;
  final int sampleRate;
  final int durationMs;
}
