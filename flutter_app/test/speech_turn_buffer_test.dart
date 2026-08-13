import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:snail/services/audio_policy.dart';
import 'package:snail/services/audio_processor.dart';
import 'package:snail/services/speech_turn_buffer.dart';

/// 40 ms of 16 kHz mono PCM16 — the native capture chunk size.
const _chunkBytes = 1280;
const _chunkDuration = Duration(milliseconds: 40);

/// Extracts the PCM payload of a canonical RIFF/WAVE file.
Uint8List _wavPcm(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  var offset = 12; // past "RIFF" size "WAVE"
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      return Uint8List.sublistView(bytes, offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in $path');
}

List<Uint8List> _chunks(Uint8List pcm) => [
      for (var i = 0; i + _chunkBytes <= pcm.length; i += _chunkBytes)
        Uint8List.sublistView(pcm, i, i + _chunkBytes),
    ];

void main() {
  // Every recorded sentence the pipeline is expected to handle.
  final samples = <String>[
    for (var i = 1; i <= 10; i++) '../audio_samples/S$i.wav',
  ];

  group('SpeechTurnBuffer with recorded speech', () {
    for (final path in samples) {
      test('$path yields contiguous turns split only on real pauses', () {
        final chunks = _chunks(_wavPcm(path));
        expect(chunks.length, greaterThan(20));
        final isSpeech = [
          for (final chunk in chunks)
            !AudioProcessor.detectSilence(chunk,
                threshold: AudioPolicy.defaultNoiseGate)
        ];

        const turnSilence = Duration(milliseconds: 800);
        const maxTurn = Duration(seconds: 12);
        final buffer = SpeechTurnBuffer(
            gateThreshold: AudioPolicy.defaultNoiseGate,
            turnSilence: turnSilence,
            maxTurn: maxTurn);
        var now = DateTime(2026, 1, 1);

        // Drive the buffer exactly like the session screen does, then check
        // where it chose to cut the stream into turns.
        final turnLengths = <int>[];
        final boundaries = <int>[];
        // Trailing silence so the final turn also completes.
        final totalChunks = chunks.length + 25;
        for (var i = 0; i < totalChunks; i++) {
          buffer.add(
              i < chunks.length ? chunks[i] : Uint8List(_chunkBytes), now);
          now = now.add(_chunkDuration);
          if (buffer.isTurnComplete(now)) {
            final turn = buffer.takeTurn();
            if (turn != null) {
              turnLengths.add(turn.length);
              boundaries.add(i);
            }
          }
        }

        expect(turnLengths, isNotEmpty, reason: 'no turn was produced');

        var start = 0;
        for (var t = 0; t < boundaries.length; t++) {
          final end = boundaries[t];
          var first = -1;
          var last = -1;
          for (var i = start; i <= end && i < isSpeech.length; i++) {
            if (!isSpeech[i]) continue;
            if (first < 0) first = i;
            last = i;
          }
          expect(first, greaterThanOrEqualTo(0),
              reason: 'turn $t contains no speech at all');

          // Anti-splicing: the turn must still contain the pauses that sit
          // between its own words. Gating chunk-by-chunk kept only 34-69 % of
          // these samples and glued the survivors together, which is what
          // made ASR return syllables instead of sentences.
          expect(turnLengths[t], greaterThanOrEqualTo((last - first + 1) * _chunkBytes),
              reason: 'turn $t dropped its internal pauses');

          // A turn may only be cut on a pause that is genuinely long enough
          // to be an utterance boundary, never mid-phrase. The turn is
          // evaluated one chunk after the boundary chunk was fed, so the
          // elapsed silence spans (end - last + 1) chunks. The max-turn cap
          // is the documented exception: it is a safety valve for a speaker
          // who never pauses.
          final silenceMs = (end - last + 1) * _chunkDuration.inMilliseconds;
          final turnMs = (end - first + 1) * _chunkDuration.inMilliseconds;
          if (turnMs < maxTurn.inMilliseconds) {
            expect(silenceMs, greaterThanOrEqualTo(turnSilence.inMilliseconds),
                reason: 'turn $t was cut after only $silenceMs ms of silence');
          }
          start = end + 1;
        }

        // Nothing spoken may be left behind unspoken.
        final trailingSpeech = [
          for (var i = start; i < isSpeech.length; i++) isSpeech[i]
        ].any((value) => value);
        expect(trailingSpeech, isFalse,
            reason: 'speech after the last turn was never transcribed');
      });
    }

    test('pre-roll keeps audio from before the gate opens', () {
      final buffer = SpeechTurnBuffer(
          gateThreshold: AudioPolicy.defaultNoiseGate, preRollChunks: 3);
      var now = DateTime(2026, 1, 1);
      for (var i = 0; i < 10; i++) {
        buffer.add(Uint8List(_chunkBytes), now);
        now = now.add(_chunkDuration);
      }
      expect(buffer.bufferedBytes, 0);

      final speech = _chunks(_wavPcm('../audio_samples/S1.wav'))
          .firstWhere((chunk) => !AudioProcessor.detectSilence(chunk,
              threshold: AudioPolicy.defaultNoiseGate));
      buffer.add(speech, now);
      // The speech chunk plus the three retained pre-roll chunks.
      expect(buffer.bufferedBytes, 4 * _chunkBytes);
    });

    test('trailing silence is capped by the hangover', () {
      final buffer = SpeechTurnBuffer(
        gateThreshold: AudioPolicy.defaultNoiseGate,
        hangover: const Duration(milliseconds: 200),
      );
      var now = DateTime(2026, 1, 1);
      final speech = _chunks(_wavPcm('../audio_samples/S1.wav'))
          .firstWhere((chunk) => !AudioProcessor.detectSilence(chunk,
              threshold: AudioPolicy.defaultNoiseGate));
      buffer.add(speech, now);
      now = now.add(_chunkDuration);
      for (var i = 0; i < 100; i++) {
        buffer.add(Uint8List(_chunkBytes), now);
        now = now.add(_chunkDuration);
      }
      // 1 speech chunk + at most 200 ms (5 chunks) of trailing silence.
      expect(buffer.bufferedBytes, lessThanOrEqualTo(6 * _chunkBytes));
    });

    test('short noise below the minimum turn length is not transcribed', () {
      final buffer =
          SpeechTurnBuffer(gateThreshold: AudioPolicy.defaultNoiseGate);
      var now = DateTime(2026, 1, 1);
      final speech = _chunks(_wavPcm('../audio_samples/S1.wav'))
          .firstWhere((chunk) => !AudioProcessor.detectSilence(chunk,
              threshold: AudioPolicy.defaultNoiseGate));
      buffer.add(speech, now);
      now = now.add(const Duration(seconds: 5));
      expect(buffer.isTurnComplete(now), isFalse);
    });

    test('reset drops a running turn', () {
      final buffer =
          SpeechTurnBuffer(gateThreshold: AudioPolicy.defaultNoiseGate);
      final now = DateTime(2026, 1, 1);
      for (final chunk in _chunks(_wavPcm('../audio_samples/S1.wav'))) {
        buffer.add(chunk, now);
      }
      expect(buffer.bufferedBytes, greaterThan(0));
      buffer.reset();
      expect(buffer.bufferedBytes, 0);
      expect(buffer.hasSpeech, isFalse);
      expect(buffer.takeTurn(), isNull);
    });
  });
}
