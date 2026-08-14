import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snail/services/audio_policy.dart';
import 'package:snail/services/snail_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('auto profile uses the device route and does not force echo guard', () {
    final policy = AudioPolicy();
    expect(policy.profile, AudioPolicyProfile.auto);
    expect(policy.forceEchoGuard, isFalse);
    expect(policy.preferLongTurns, isFalse);
    expect(policy.output, AudioOutput.auto);
  });

  test('speaker profile forces echo guard without long-turn behavior', () async {
    final policy = AudioPolicy();
    await policy.setProfile(AudioPolicyProfile.speakerEcho);
    expect(policy.forceEchoGuard, isTrue);
    expect(policy.preferLongTurns, isFalse);
    expect(policy.output, AudioOutput.speaker);
  });

  test('longer-speech profile keeps turn output from being discarded', () async {
    final policy = AudioPolicy();
    await policy.setProfile(AudioPolicyProfile.longerSpeech);
    expect(policy.forceEchoGuard, isFalse);
    expect(policy.preferLongTurns, isTrue);
  });

  group('orthogonal properties', () {
    test('setOutput changes output independently', () async {
      final policy = AudioPolicy();
      await policy.setOutput(AudioOutput.speaker);
      expect(policy.output, AudioOutput.speaker);
      expect(policy.forceEchoGuard, isFalse);
      expect(policy.preferLongTurns, isFalse);
    });

    test('setEchoGuard changes echo guard independently', () async {
      final policy = AudioPolicy();
      await policy.setEchoGuard(true);
      expect(policy.forceEchoGuard, isTrue);
      expect(policy.output, AudioOutput.auto);
      expect(policy.preferLongTurns, isFalse);
    });

    test('setLongTurns changes long-turn preference independently', () async {
      final policy = AudioPolicy();
      await policy.setLongTurns(true);
      expect(policy.preferLongTurns, isTrue);
      expect(policy.output, AudioOutput.auto);
      expect(policy.forceEchoGuard, isFalse);
    });

    test('headset profile maps to headset output, no echo guard', () async {
      final policy = AudioPolicy();
      await policy.setProfile(AudioPolicyProfile.headset);
      expect(policy.output, AudioOutput.headset);
      expect(policy.forceEchoGuard, isFalse);
      expect(policy.preferLongTurns, isFalse);
    });

    test('label reflects current state', () async {
      final policy = AudioPolicy();
      expect(policy.label, 'Automatisch');
      await policy.setOutput(AudioOutput.speaker);
      await policy.setEchoGuard(true);
      expect(policy.label, 'Lautsprecher, Echo-Schutz');
    });
  });

  test('persists every independent setting across a load cycle', () async {
    final policy = AudioPolicy();
    await policy.setOutput(AudioOutput.speaker);
    await policy.setEchoGuard(false);
    await policy.setLongTurns(true);

    final restored = AudioPolicy();
    await restored.load();
    expect(restored.output, AudioOutput.speaker);
    expect(restored.forceEchoGuard, isFalse);
    expect(restored.preferLongTurns, isTrue);
  });

  test('migrates the legacy profile once without collapsing new settings', () async {
    SharedPreferences.setMockInitialValues({'audio_policy_profile': 'speakerEcho'});
    final restored = AudioPolicy();
    await restored.load();
    expect(restored.output, AudioOutput.speaker);
    expect(restored.forceEchoGuard, isTrue);
    expect(restored.preferLongTurns, isFalse);

    await restored.setEchoGuard(false);
    final secondLoad = AudioPolicy();
    await secondLoad.load();
    expect(secondLoad.output, AudioOutput.speaker);
    expect(secondLoad.forceEchoGuard, isFalse);
    expect(secondLoad.preferLongTurns, isFalse);
  });
}
