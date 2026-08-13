import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'snail_audio.dart';

/// Legacy profile kept for backward-compatible persistence.
/// New code should use the individual [output], [forceEchoGuard],
/// and [preferLongTurns] properties directly.
enum AudioPolicyProfile { auto, headset, speakerEcho, longerSpeech }

/// Central audio routing and behaviour policy.
///
/// Separates three orthogonal concerns:
/// - [output] — which device plays translated audio
/// - [forceEchoGuard] — whether to suppress capture during playback
/// - [preferLongTurns] — whether to keep turn output alive longer
class AudioPolicy extends ChangeNotifier {
  static const _key = 'audio_policy_profile';
  // v4 stores a true RMS threshold. Values persisted under the v3 key were
  // mean-square and are ~20x smaller for the same loudness, so reusing them
  // would silently disable the gate.
  static const _noiseGateKey = 'audio_noise_gate_threshold_v4';

  /// -34 dBFS. Speech on a phone microphone sits near -22 dBFS, room tone
  /// well below -45 dBFS, so this passes normal talking and blocks hiss.
  static const defaultNoiseGate = 0.02;

  /// -20 dBFS. Above this a gate would start cutting normal speech.
  static const maxNoiseGate = 0.1;

  AudioOutput _output = AudioOutput.auto;
  bool _echoGuard = false;
  bool _longTurns = false;
  double _noiseGateThreshold = defaultNoiseGate;

  /// Which device should play translated audio.
  AudioOutput get output => _output;

  /// Whether the echo guard should be forced on (speaker mode).
  bool get forceEchoGuard => _echoGuard;

  /// Whether turn output should be kept alive longer.
  bool get preferLongTurns => _longTurns;

  /// RMS threshold below which captured audio is treated as silence.
  double get noiseGateThreshold => _noiseGateThreshold;

  /// Human-readable label for the current policy.
  String get label {
    final device = switch (_output) {
      AudioOutput.speaker => 'Lautsprecher',
      AudioOutput.headset => 'Headset',
      AudioOutput.auto => 'Automatisch',
    };
    final echo = _echoGuard ? ', Echo-Schutz' : '';
    final turns = _longTurns ? ', längere Sätze' : '';
    return '$device$echo$turns';
  }

  /// Legacy profile getter for backward compatibility.
  /// Maps the three orthogonal properties to the closest legacy profile.
  AudioPolicyProfile get profile => _toLegacyProfile();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key);
      _noiseGateThreshold = (prefs.getDouble(_noiseGateKey) ?? defaultNoiseGate)
          .clamp(0.0, maxNoiseGate)
          .toDouble();
      final profile = AudioPolicyProfile.values.firstWhere(
        (item) => item.name == value,
        orElse: () => AudioPolicyProfile.auto,
      );
      _applyProfile(profile);
    } catch (_) {
      _applyProfile(AudioPolicyProfile.auto);
    }
    notifyListeners();
  }

  /// Set the output device independently.
  Future<void> setOutput(AudioOutput value) async {
    if (_output == value) return;
    _output = value;
    notifyListeners();
    await _persist();
  }

  /// Set echo guard independently.
  Future<void> setEchoGuard(bool value) async {
    if (_echoGuard == value) return;
    _echoGuard = value;
    notifyListeners();
    await _persist();
  }

  /// Set long-turn preference independently.
  Future<void> setLongTurns(bool value) async {
    if (_longTurns == value) return;
    _longTurns = value;
    notifyListeners();
    await _persist();
  }

  Future<void> setNoiseGateThreshold(double value) async {
    final next = value.clamp(0.0, maxNoiseGate).toDouble();
    if ((_noiseGateThreshold - next).abs() < 0.0001) return;
    _noiseGateThreshold = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_noiseGateKey, next);
    } catch (_) {}
  }

  /// Legacy setter — maps a profile to the three orthogonal properties.
  Future<void> setProfile(AudioPolicyProfile value) async {
    _applyProfile(value);
    notifyListeners();
    await _persist();
  }

  // ── Internal ────────────────────────────────────────────────────────

  void _applyProfile(AudioPolicyProfile profile) {
    switch (profile) {
      case AudioPolicyProfile.auto:
        _output = AudioOutput.auto;
        _echoGuard = false;
        _longTurns = false;
      case AudioPolicyProfile.headset:
        _output = AudioOutput.headset;
        _echoGuard = false;
        _longTurns = false;
      case AudioPolicyProfile.speakerEcho:
        _output = AudioOutput.speaker;
        _echoGuard = true;
        _longTurns = false;
      case AudioPolicyProfile.longerSpeech:
        _output = AudioOutput.auto;
        _echoGuard = false;
        _longTurns = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Persist as the closest legacy profile for backward compat.
      final profile = _toLegacyProfile();
      await prefs.setString(_key, profile.name);
    } catch (_) {
      // In-memory state remains valid even if persistence fails.
    }
  }

  AudioPolicyProfile _toLegacyProfile() {
    if (_output == AudioOutput.headset && !_echoGuard && !_longTurns) {
      return AudioPolicyProfile.headset;
    }
    if (_output == AudioOutput.speaker && _echoGuard && !_longTurns) {
      return AudioPolicyProfile.speakerEcho;
    }
    if (_longTurns) return AudioPolicyProfile.longerSpeech;
    return AudioPolicyProfile.auto;
  }
}
