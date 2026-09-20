import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'snail_audio.dart';

/// Records a voice note for the chat.
///
/// The relay caps a voice payload at 64 KB of base64 characters, which at
/// 16 kHz mono PCM16 is roughly 24 seconds of audio. The recorder enforces a
/// duration limit so a long recording is stopped rather than rejected on send.
class VoiceRecorder {
  VoiceRecorder({required this.audio, this.maxDuration = const Duration(seconds: 20)});

  final SnailAudio audio;

  /// Hard stop; a recording longer than this would exceed the relay's cap.
  final Duration maxDuration;

  static const sampleRate = 16000;

  StreamSubscription<Map<String, dynamic>>? _subscription;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  DateTime? _startedAt;
  Timer? _limitTimer;
  bool _recording = false;
  Completer<void>? _limitReached;

  bool get isRecording => _recording;

  /// Elapsed time of the current recording.
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Fires when [maxDuration] is reached, so the UI can stop and send.
  Future<void> get onLimitReached =>
      _limitReached?.future ?? Future<void>.value();

  /// Starts capturing. Returns false when the microphone is unavailable.
  Future<bool> start() async {
    if (_recording) return true;
    _pcm.clear();
    final started = await audio.startStandaloneCapture(sampleRate: sampleRate);
    if (!started) return false;
    _startedAt = DateTime.now();
    _recording = true;
    _limitReached = Completer<void>();
    _subscription = audio.standaloneStream?.listen((frame) {
      if (!_recording) return;
      final bytes = frame['bytes'];
      if (bytes is Uint8List) _pcm.add(bytes);
    });
    _limitTimer = Timer(maxDuration, () {
      if (!(_limitReached?.isCompleted ?? true)) _limitReached!.complete();
    });
    return true;
  }

  /// Stops capturing and returns the recording, or null when nothing was
  /// captured (a tap that produced no audio must not send an empty note).
  Future<VoiceNote?> stop() async {
    if (!_recording) return null;
    _recording = false;
    _limitTimer?.cancel();
    _limitTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await audio.stopStandaloneCapture();
    final bytes = _pcm.takeBytes();
    final durationMs = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inMilliseconds;
    _startedAt = null;
    if (bytes.isEmpty || durationMs <= 0) return null;
    return VoiceNote(
      audioData: base64Encode(bytes),
      durationMs: durationMs,
      sampleRate: sampleRate,
    );
  }

  /// Aborts without producing a note.
  Future<void> cancel() async {
    if (!_recording) return;
    _recording = false;
    _limitTimer?.cancel();
    _limitTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await audio.stopStandaloneCapture();
    _pcm.clear();
    _startedAt = null;
  }

  void dispose() {
    _limitTimer?.cancel();
    _subscription?.cancel();
  }
}

/// A finished recording, ready to be sent.
class VoiceNote {
  const VoiceNote({
    required this.audioData,
    required this.durationMs,
    required this.sampleRate,
  });

  final String audioData;
  final int durationMs;
  final int sampleRate;

  /// `m:ss` for the bubble label.
  String get label {
    final seconds = (durationMs / 1000).round();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
