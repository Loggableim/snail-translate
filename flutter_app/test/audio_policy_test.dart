import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/audio_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('auto profile uses the device route and does not force echo guard', () {
    final policy = AudioPolicy();
    expect(policy.profile, AudioPolicyProfile.auto);
    expect(policy.forceEchoGuard, isFalse);
    expect(policy.preferLongTurns, isFalse);
  });

  test('speaker profile forces echo guard without long-turn behavior', () async {
    final policy = AudioPolicy();
    await policy.setProfile(AudioPolicyProfile.speakerEcho);
    expect(policy.forceEchoGuard, isTrue);
    expect(policy.preferLongTurns, isFalse);
  });

  test('longer-speech profile keeps turn output from being discarded', () async {
    final policy = AudioPolicy();
    await policy.setProfile(AudioPolicyProfile.longerSpeech);
    expect(policy.forceEchoGuard, isFalse);
    expect(policy.preferLongTurns, isTrue);
  });
}
