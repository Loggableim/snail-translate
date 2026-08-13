import 'dart:typed_data';

import 'audio_processor.dart';

/// Collects captured microphone chunks into complete spoken turns for ASR.
///
/// The naive approach — forward every chunk whose RMS clears the noise gate —
/// looks correct per chunk but destroys the utterance: measured against the
/// German samples in `audio_samples/`, a 7-second sentence lost 32 % of its
/// 40 ms chunks and reached ASR as 17 spliced fragments with every pause
/// removed. That is what made Fish ASR return syllables and word fragments
/// instead of sentences.
///
/// This buffer instead uses the gate only to decide where a turn *starts* and
/// *ends*:
///
/// - a [preRollChunks] ring keeps audio from before the gate opened, so the
///   first syllable is not clipped off by the gate's attack,
/// - once a turn is running every chunk is kept, silent or not, preserving the
///   natural pauses inside the sentence,
/// - the turn ends after [turnSilence] without speech, bounded by [maxTurn],
/// - trailing silence is capped at [hangover] so a stalled ASR request cannot
///   grow the buffer without limit.
class SpeechTurnBuffer {
  SpeechTurnBuffer({
    required this.gateThreshold,
    this.preRollChunks = 5,
    this.hangover = const Duration(milliseconds: 1500),
    this.turnSilence = const Duration(milliseconds: 800),
    this.maxTurn = const Duration(seconds: 12),
    this.minTurnBytes = 32000,
  });

  /// RMS level below which a chunk counts as silence. Mutable because the
  /// session screen exposes it as a live slider.
  double gateThreshold;

  /// Number of pre-gate chunks replayed at the start of a turn.
  final int preRollChunks;

  /// Longest trailing silence appended after the speaker stops.
  final Duration hangover;

  /// Silence that ends a turn. Real sentences contain pauses close to one
  /// second, so this must stay above them or turns get cut mid-sentence.
  final Duration turnSilence;

  /// Hard cap so a continuously speaking user still produces turns. This is a
  /// safety valve only and is the one boundary that can land mid-word, so it
  /// must stay well above a normal spoken sentence (~5 s).
  final Duration maxTurn;

  /// Shortest turn worth sending to ASR (32000 bytes = 1 s of 16 kHz PCM16).
  final int minTurnBytes;

  final List<Uint8List> _preRoll = <Uint8List>[];
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _speechDetected = false;
  DateTime? _lastSpeechAt;
  DateTime? _turnStartedAt;

  /// True once the gate has opened for the current turn.
  bool get hasSpeech => _speechDetected;

  /// Bytes currently held for the running turn.
  int get bufferedBytes => _buffer.length;

  /// Feed one captured chunk. [now] is injected so turn timing is testable.
  void add(Uint8List chunk, DateTime now) {
    final isSpeech =
        !AudioProcessor.detectSilence(chunk, threshold: gateThreshold);
    if (isSpeech) {
      if (!_speechDetected) {
        _speechDetected = true;
        _turnStartedAt = now;
        for (final preRoll in _preRoll) {
          _buffer.add(preRoll);
        }
      }
      _preRoll.clear();
      _lastSpeechAt = now;
      _buffer.add(chunk);
      return;
    }
    if (_speechDetected) {
      if (_lastSpeechAt != null && now.difference(_lastSpeechAt!) < hangover) {
        _buffer.add(chunk);
      }
      return;
    }
    _preRoll.add(chunk);
    if (_preRoll.length > preRollChunks) _preRoll.removeAt(0);
  }

  /// Whether the running turn is finished and long enough to transcribe.
  bool isTurnComplete(DateTime now) {
    if (!_speechDetected || _buffer.length < minTurnBytes) return false;
    final sinceSpeech =
        _lastSpeechAt == null ? maxTurn : now.difference(_lastSpeechAt!);
    final turnAge =
        _turnStartedAt == null ? Duration.zero : now.difference(_turnStartedAt!);
    return sinceSpeech >= turnSilence || turnAge >= maxTurn;
  }

  /// Removes and returns the completed turn, leaving the buffer ready for the
  /// next one. Returns null when nothing has been captured.
  Uint8List? takeTurn() {
    if (_buffer.isEmpty) return null;
    final pcm = _buffer.takeBytes();
    _speechDetected = false;
    _lastSpeechAt = null;
    _turnStartedAt = null;
    return pcm;
  }

  /// Drops all captured audio, e.g. when the user mutes.
  void reset() {
    _buffer.clear();
    _preRoll.clear();
    _speechDetected = false;
    _lastSpeechAt = null;
    _turnStartedAt = null;
  }
}
