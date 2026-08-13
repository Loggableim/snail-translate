import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Audio output device for playback routing.
enum AudioOutput { speaker, headset, auto }

enum AudioInput { phone, headset, auto }

/// Flutter interface to the native SnailAudioPlugin (Android/iOS).
///
/// Provides:
/// - Acoustic Echo Cancellation (AEC) via Android AudioFX / iOS AVAudioSession
/// - Noise Suppression
/// - Low-latency audio capture with AEC applied
///
/// Usage:
///   final audio = SnailAudio();
///   await audio.initialize(sampleRate: 16000);
///   audio.audioStream.listen((bytes) {
///     // Send bytes to WebSocket
///   });
///   await audio.startCapture();
class SnailAudio {
  static const _methodChannel = MethodChannel('com.snail.audio/method');
  static const _eventChannel = EventChannel('com.snail.audio/stream');
  static const _standaloneEventChannel =
      EventChannel('com.snail.audio/standalone_stream');

  Stream<Uint8List>? _audioStream;
  Stream<Map<String, dynamic>>? _standaloneStream;
  bool _isInitialized = false;
  bool _isCapturing = false;
  DateTime _playbackUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _echoGuardEnabled = true;

  // ── Properties ──────────────────────────────────────────────────────

  bool get isInitialized => _isInitialized;
  bool get isCapturing => _isCapturing;

  /// True while translated playback is audible. Capture forwarding uses this
  /// as a short echo guard for close-range phone-to-phone tests.
  bool get isPlaybackActive => DateTime.now().isBefore(_playbackUntil);
  bool get echoGuardEnabled => _echoGuardEnabled;
  Stream<Uint8List>? get audioStream => _audioStream;
  Stream<Map<String, dynamic>>? get standaloneStream => _standaloneStream;

  Future<bool> startStandaloneCapture(
      {int sampleRate = 16000,
      bool aecEnabled = true,
      bool noiseSuppressionEnabled = true}) async {
    try {
      // Subscribe before starting the native recorder. Otherwise the native
      // thread can emit its first frames while no EventChannel listener is
      // attached yet, which made the standalone screen appear idle on some
      // devices even though capture had already started.
      _standaloneStream =
          _standaloneEventChannel.receiveBroadcastStream().map((data) {
        final value = Map<dynamic, dynamic>.from(data as Map);
        return {
          'source': value['source'] as String,
          'bytes':
              Uint8List.fromList((value['bytes'] as List<dynamic>).cast<int>()),
          'sampleRate': value['sampleRate'] as int? ?? sampleRate
        };
      });
      final ok =
          await _methodChannel.invokeMethod<bool>('startStandaloneCapture', {
                'sampleRate': sampleRate,
                'aecEnabled': aecEnabled,
                'noiseSuppressionEnabled': noiseSuppressionEnabled,
              }) ??
              false;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopStandaloneCapture() async {
    try {
      await _methodChannel.invokeMethod('stopStandaloneCapture');
    } catch (e) {
      debugPrint('[SnailAudio] stopStandaloneCapture error: $e');
    }
  }

  // ── Initialization ─────────────────────────────────────────────────

  /// Initialize audio capture with AEC and noise suppression.
  ///
  /// [sampleRate] — 16000 (recommended for STT) or 48000
  /// [aecEnabled] — enable Acoustic Echo Cancellation (default: true)
  /// [noiseSuppressionEnabled] — enable Noise Suppression (default: true)
  Future<bool> initialize({
    int sampleRate = 16000,
    bool aecEnabled = true,
    bool noiseSuppressionEnabled = true,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('initialize', {
        'sampleRate': sampleRate,
        'aecEnabled': aecEnabled,
        'noiseSuppressionEnabled': noiseSuppressionEnabled,
      });
      _isInitialized = result ?? false;
      if (_isInitialized) {
        final hasHeadset = await isHeadsetConnected();
        _echoGuardEnabled = !hasHeadset;
      }

      // Set up audio stream
      _audioStream = _eventChannel
          .receiveBroadcastStream()
          .map((data) => Uint8List.fromList(data as List<int>));

      return _isInitialized;
    } catch (e) {
      debugPrint('SnailAudio initialize error: $e');
      return false;
    }
  }

  Future<bool> requestMicrophonePermission() async {
    try {
      return await _methodChannel
              .invokeMethod<bool>('requestMicrophonePermission') ??
          false;
    } catch (e) {
      debugPrint('SnailAudio microphone permission error: $e');
      return false;
    }
  }

  // ── Capture Control ────────────────────────────────────────────────

  /// Start audio capture with AEC.
  Future<bool> startCapture() async {
    if (!_isInitialized) {
      throw StateError('SnailAudio not initialized. Call initialize() first.');
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('startCapture');
      _isCapturing = result ?? false;
      return _isCapturing;
    } catch (e) {
      debugPrint('SnailAudio startCapture error: $e');
      return false;
    }
  }

  /// Stop audio capture.
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    try {
      await _methodChannel.invokeMethod('stopCapture');
    } catch (e) {
      debugPrint('SnailAudio stopCapture error: $e');
    }
    _isCapturing = false;
  }

  /// Pause audio capture without full teardown (app background).
  Future<void> pauseCapture() async {
    if (!_isCapturing) return;
    try {
      await _methodChannel.invokeMethod('pauseCapture');
    } catch (e) {
      debugPrint('SnailAudio pauseCapture error: $e');
    }
  }

  /// Resume audio capture after pause (app foreground).
  Future<void> resumeCapture() async {
    if (!_isCapturing) return;
    try {
      await _methodChannel.invokeMethod('resumeCapture');
    } catch (e) {
      debugPrint('SnailAudio resumeCapture error: $e');
    }
  }

  /// Plays raw mono PCM16. Gemini Live outputs 24-kHz PCM; callers must not
  /// pass MP3/container bytes to this method.
  Future<void> playPcm16(Uint8List bytes,
      {int sampleRate = 24000, AudioOutput output = AudioOutput.auto}) async {
    if (bytes.isEmpty) return;
    final durationMs = ((bytes.length * 1000) / (sampleRate * 2)).ceil();
    // Only cover the measured chunk duration plus a small acoustic tail. The
    // hardware AEC remains the primary mechanism; this is not a half-duplex
    // mute and should not swallow normal speech.
    _playbackUntil =
        DateTime.now().add(Duration(milliseconds: durationMs + 100));
    try {
      await _methodChannel.invokeMethod('playPcm16', {
        'bytes': bytes.toList(growable: false),
        'sampleRate': sampleRate,
        'output': output.name
      });
    } catch (e) {
      debugPrint('SnailAudio playback error: $e');
    }
  }

  /// Immediately clears already queued translated speech when the user mutes.
  Future<void> stopPlayback() async {
    try {
      await _methodChannel.invokeMethod('stopPlayback');
    } catch (e) {
      debugPrint('SnailAudio stop playback error: $e');
    }
  }

  /// Apply a session output choice immediately, including while capture is
  /// already running.
  Future<void> setOutput(AudioOutput output) async {
    try {
      await _methodChannel.invokeMethod('setOutput', {'output': output.name});
    } catch (e) {
      debugPrint('SnailAudio set output error: $e');
    }
  }

  /// Plays a short 660-Hz tone through the phone speaker. This is a local
  /// diagnostic only: no microphone, provider, or network is used.
  Future<bool> playTestTone() async {
    try {
      return await _methodChannel.invokeMethod<bool>('playTestTone') ?? false;
    } catch (e) {
      debugPrint('SnailAudio test tone error: $e');
      return false;
    }
  }

  Future<void> startSessionKeepAlive() async {
    try {
      await _methodChannel.invokeMethod('startSessionKeepAlive');
    } catch (e) {
      debugPrint('SnailAudio keep-alive start error: $e');
    }
  }

  Future<void> stopSessionKeepAlive() async {
    try {
      await _methodChannel.invokeMethod('stopSessionKeepAlive');
    } catch (e) {
      debugPrint('SnailAudio keep-alive stop error: $e');
    }
  }

  // ── Feature Detection ──────────────────────────────────────────────

  /// Check if AEC is available on this device.
  Future<bool> isAecAvailable() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isAecAvailable') ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Check if Noise Suppression is available on this device.
  Future<bool> isNoiseSuppressorAvailable() async {
    try {
      return await _methodChannel
              .invokeMethod<bool>('isNoiseSuppressorAvailable') ??
          false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> isHeadsetConnected() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isHeadsetConnected') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setInput(AudioInput input) async {
    try {
      await _methodChannel.invokeMethod('setInput', {'input': input.name});
    } catch (e) {
      debugPrint('SnailAudio input route error: $e');
    }
  }

  Future<Map<String, dynamic>> getAudioDiagnostics() async {
    try {
      final value =
          await _methodChannel.invokeMethod<dynamic>('getAudioDiagnostics');
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
    } catch (e) {
      debugPrint('SnailAudio diagnostics error: $e');
    }
    return const <String, dynamic>{};
  }

  // ── Runtime Control ────────────────────────────────────────────────

  /// Enable/disable AEC at runtime.
  Future<void> setAecEnabled(bool enabled) async {
    try {
      await _methodChannel.invokeMethod('setAecEnabled', {'enabled': enabled});
    } catch (e) {
      debugPrint('SnailAudio setAecEnabled error: $e');
    }
  }

  /// Enable/disable Noise Suppression at runtime.
  Future<void> setNoiseSuppressionEnabled(bool enabled) async {
    try {
      await _methodChannel
          .invokeMethod('setNoiseSuppressionEnabled', {'enabled': enabled});
    } catch (e) {
      debugPrint('SnailAudio setNoiseSuppressionEnabled error: $e');
    }
  }

  /// Get the Android audio session ID (for external AEC integration).
  Future<int?> getAudioSessionId() async {
    try {
      return await _methodChannel.invokeMethod<int>('getAudioSessionId');
    } catch (e) {
      return null;
    }
  }

  // ── Cleanup ─────────────────────────────────────────────────────────

  /// Release all resources.
  Future<void> dispose() async {
    await stopCapture();
    _isInitialized = false;
  }
}
