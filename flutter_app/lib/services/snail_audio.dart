import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

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
  static const _sessionEventChannel =
      EventChannel('com.snail.audio/session_events');

  Stream<Uint8List>? _audioStream;
  Stream<Map<String, dynamic>>? _standaloneStream;
  bool _isInitialized = false;
  bool _isCapturing = false;
  DateTime _playbackUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _echoGuardEnabled = true;

  static bool _isValidSampleRate(int value) => value > 0 && value <= 192000;

  // ── Properties ──────────────────────────────────────────────────────

  bool get isInitialized => _isInitialized;
  bool get isCapturing => _isCapturing;

  /// True while translated playback is audible. Capture forwarding uses this
  /// as a short echo guard for close-range phone-to-phone tests.
  bool get isPlaybackActive => DateTime.now().isBefore(_playbackUntil);
  bool get echoGuardEnabled => _echoGuardEnabled;
  Stream<Uint8List>? get audioStream => _audioStream;
  Stream<Map<String, dynamic>>? get standaloneStream => _standaloneStream;
  Stream<String> get sessionEvents => _sessionEventChannel
      .receiveBroadcastStream()
      .where((event) => event == 'ended')
      .cast<String>();

  Future<bool> startStandaloneCapture(
      {int sampleRate = 16000,
      bool aecEnabled = true,
      bool noiseSuppressionEnabled = true}) async {
    if (!_isValidSampleRate(sampleRate)) return false;
    // Desktop has no SnailAudioPlugin. The guide needs a microphone there, so
    // capture goes through the WebRTC audio stack that flutter_webrtc already
    // ships for Windows.
    if (_isDesktop) {
      return _startDesktopCapture(sampleRate);
    }
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

  /// True on platforms without the native SnailAudioPlugin.
  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Desktop capture through the `record` package.
  ///
  /// Emits the same frame shape as the Android path (`source`, `bytes`,
  /// `sampleRate`) so the guide pipeline is platform-agnostic. The source is
  /// always `phone`: desktop has no second microphone to route.
  ///
  /// The stream is 16 kHz mono PCM16, which is exactly what the ASR expects —
  /// no resampling step is needed on this path.
  Future<bool> _startDesktopCapture(int sampleRate) async {
    try {
      final recorder = AudioRecorder();
      if (!await recorder.hasPermission()) {
        debugPrint('[SnailAudio] desktop microphone permission denied');
        return false;
      }
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _desktopRecorder = recorder;

      final controller = StreamController<Map<String, dynamic>>.broadcast();
      _desktopController = controller;
      _desktopSubscription = stream.listen(
        (bytes) {
          if (controller.isClosed || bytes.isEmpty) return;
          controller.add({
            'source': 'phone',
            'bytes': bytes,
            'sampleRate': sampleRate,
          });
        },
        onError: (Object error) =>
            debugPrint('[SnailAudio] desktop capture stream error: $error'),
      );

      _standaloneStream = controller.stream;
      _isCapturing = true;
      return true;
    } catch (error) {
      debugPrint('[SnailAudio] desktop capture failed: $error');
      return false;
    }
  }

  AudioRecorder? _desktopRecorder;
  StreamSubscription<Uint8List>? _desktopSubscription;
  StreamController<Map<String, dynamic>>? _desktopController;

  Future<void> stopStandaloneCapture() async {
    if (_isDesktop) {
      _isCapturing = false;
      try {
        await _desktopSubscription?.cancel();
      } catch (_) {}
      _desktopSubscription = null;
      try {
        await _desktopRecorder?.stop();
      } catch (_) {}
      try {
        await _desktopRecorder?.dispose();
      } catch (_) {}
      _desktopRecorder = null;
      try {
        await _desktopController?.close();
      } catch (_) {}
      _desktopController = null;
      _standaloneStream = null;
      return;
    }
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
    if (!_isValidSampleRate(sampleRate)) return false;
    // Desktop has no native audio plugin: there is no session to initialize.
    // Capture starts on demand through the WebRTC path, so this reports
    // success without touching a channel that does not exist.
    if (_isDesktop) {
      _isInitialized = true;
      _echoGuardEnabled = false;
      return true;
    }
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
    // Desktop has no runtime permission dialog: the OS grants access on the
    // first getUserMedia call, and a denial surfaces as a capture failure.
    if (_isDesktop) return true;
    try {
      return await _methodChannel
              .invokeMethod<bool>('requestMicrophonePermission') ??
          false;
    } catch (e) {
      debugPrint('SnailAudio microphone permission error: $e');
      return false;
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _methodChannel.invokeMethod('openAppSettings');
    } catch (e) {
      debugPrint('SnailAudio open app settings error: $e');
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      return await _methodChannel
              .invokeMethod<bool>('requestNotificationPermission') ??
          false;
    } catch (e) {
      debugPrint('SnailAudio notification permission error: $e');
      return false;
    }
  }

  // ── Capture Control ────────────────────────────────────────────────

  /// Start audio capture with AEC.
  Future<bool> startCapture() async {
    if (!_isInitialized) {
      throw StateError('SnailAudio not initialized. Call initialize() first.');
    }

    // Desktop has no native capture session; the same `record`-based path the
    // standalone flow uses feeds the session's audio stream.
    if (_isDesktop) {
      final started = await _startDesktopCapture(16000);
      if (started) {
        _audioStream = _standaloneStream?.map((frame) {
          return frame['bytes'] as Uint8List;
        });
      }
      return started;
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

    if (_isDesktop) {
      await stopStandaloneCapture();
      _audioStream = null;
      _isCapturing = false;
      return;
    }

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
    if (bytes.isEmpty || !_isValidSampleRate(sampleRate)) return;
    final durationMs = ((bytes.length * 1000) / (sampleRate * 2)).ceil();
    // Only cover the measured chunk duration plus a small acoustic tail. The
    // hardware AEC remains the primary mechanism; this is not a half-duplex
    // mute and should not swallow normal speech.
    _playbackUntil =
        DateTime.now().add(Duration(milliseconds: durationMs + 100));
    // Desktop has no native player. Translated audio is not essential there —
    // the listener reads subtitles and the guide monitors its own text — so
    // this is a deliberate no-op rather than a silent failure.
    if (_isDesktop) return;
    try {
      // Pass the Uint8List straight through. The standard codec maps it to a
      // Java byte[]; converting to List<int> first boxed every single sample
      // into an Integer on both sides, which produced tens of thousands of
      // short-lived objects per chunk and made playback stutter under GC.
      await _methodChannel.invokeMethod('playPcm16',
          {'bytes': bytes, 'sampleRate': sampleRate, 'output': output.name});
    } catch (e) {
      debugPrint('SnailAudio playback error: $e');
    }
  }

  /// Immediately clears already queued translated speech when the user mutes.
  Future<void> stopPlayback() async {
    if (_isDesktop) return;
    try {
      await _methodChannel.invokeMethod('stopPlayback');
    } catch (e) {
      debugPrint('SnailAudio stop playback error: $e');
    }
  }

  /// Apply a session output choice immediately, including while capture is
  /// already running.
  Future<void> setOutput(AudioOutput output) async {
    // Desktop has no route control: the OS mixer decides where audio goes.
    if (_isDesktop) return;
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
    // Android-only: keeps a foreground service alive so the OS does not kill
    // capture. Desktop has no such service.
    if (_isDesktop) return;
    try {
      await _methodChannel.invokeMethod('startSessionKeepAlive');
    } catch (e) {
      debugPrint('SnailAudio keep-alive start error: $e');
    }
  }

  Future<void> stopSessionKeepAlive() async {
    if (_isDesktop) return;
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
    // Desktop has a single microphone; there is no phone/headset split.
    if (_isDesktop) return;
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
