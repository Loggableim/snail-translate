import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AudioPolicyProfile { auto, headset, speakerEcho, longerSpeech }

class AudioPolicy extends ChangeNotifier {
  static const _key = 'audio_policy_profile';
  AudioPolicyProfile _profile = AudioPolicyProfile.auto;

  AudioPolicyProfile get profile => _profile;

  bool get forceEchoGuard =>
      _profile == AudioPolicyProfile.speakerEcho;

  bool get preferLongTurns => _profile == AudioPolicyProfile.longerSpeech;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key);
      _profile = AudioPolicyProfile.values.firstWhere(
        (item) => item.name == value,
        orElse: () => AudioPolicyProfile.auto,
      );
    } catch (_) {
      _profile = AudioPolicyProfile.auto;
    }
    notifyListeners();
  }

  Future<void> setProfile(AudioPolicyProfile value) async {
    if (_profile == value) return;
    _profile = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value.name);
    } catch (_) {
      // The in-memory policy remains usable on test/web runtimes where the
      // platform preferences plugin is not registered yet.
    }
  }

  String get label => switch (_profile) {
        AudioPolicyProfile.auto => 'Automatisch (Gerät erkennt Headset)',
        AudioPolicyProfile.headset => 'Headset: schnelle Unterbrechung',
        AudioPolicyProfile.speakerEcho => 'Lautsprecher: Echo-Schutz',
        AudioPolicyProfile.longerSpeech => 'Längere Sätze: weniger Unterbrechungen',
      };
}
