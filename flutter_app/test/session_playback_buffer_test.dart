import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/session_playback_buffer.dart';

void main() {
  Uint8List pcmForMs(int milliseconds, {int sampleRate = 24000}) =>
      Uint8List((sampleRate * 2 * milliseconds) ~/ 1000);

  test('starts only after time-based prebuffer target', () {
    final buffer = SessionPlaybackBuffer();
    final at = DateTime(2026);
    buffer.add(pcmForMs(300), 24000, at);
    buffer.add(pcmForMs(300), 24000, at.add(const Duration(milliseconds: 300)));
    expect(buffer.shouldStart(), isFalse);
    buffer.add(pcmForMs(300), 24000, at.add(const Duration(milliseconds: 600)));
    expect(buffer.bufferedMs, 900);
    expect(buffer.shouldStart(), isTrue);
  });

  test('short finished utterance can flush without a timer', () {
    final buffer = SessionPlaybackBuffer();
    buffer.add(pcmForMs(300), 24000, DateTime(2026));
    expect(buffer.shouldStart(), isFalse);
    expect(buffer.shouldStart(force: true), isTrue);
  });

  test('arrival jitter raises target within bounded latency', () {
    final buffer = SessionPlaybackBuffer();
    final at = DateTime(2026);
    buffer.add(pcmForMs(300), 24000, at);
    buffer.add(pcmForMs(300), 24000, at.add(const Duration(milliseconds: 700)));
    expect(buffer.largestArrivalJitterMs, 400);
    expect(buffer.targetMs, 1550);
  });

  test('keeps bounded audio and reports dropped chunks', () {
    final buffer = SessionPlaybackBuffer(maxBufferedMs: 600);
    final at = DateTime(2026);
    buffer.add(pcmForMs(300), 24000, at);
    buffer.add(pcmForMs(300), 24000, at.add(const Duration(milliseconds: 300)));
    buffer.add(pcmForMs(300), 24000, at.add(const Duration(milliseconds: 600)));
    expect(buffer.bufferedMs, 600);
    expect(buffer.droppedChunks, 1);
  });
}
