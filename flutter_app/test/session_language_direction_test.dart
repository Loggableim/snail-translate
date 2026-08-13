import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/models/session.dart';
import 'package:snail/services/session_service.dart';

Session _session({
  required String role,
  required String sourceLang,
  required String targetLang,
}) =>
    Session(
      roomId: 'snail-4821',
      sessionToken: 'token',
      relayUrl: 'wss://example.invalid/ws?room=snail-4821',
      sourceLang: sourceLang,
      targetLang: targetLang,
      tier: 'free',
      role: role,
      quotaRemaining: 30,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('per-endpoint translation direction', () {
    test('falls back to the saved preference outside a session', () async {
      final service = SessionService();
      await service.init();
      expect(service.sessionTargetLanguage, service.targetLanguage);
    });

    test('host translates into the room target language', () async {
      final service = SessionService();
      await service.init();
      service.debugSetSession(
          _session(role: 'host', sourceLang: 'de', targetLang: 'en'));
      expect(service.sessionTargetLanguage, 'en');
    });

    test('guest adopts the mirrored direction, not its own preference',
        () async {
      // Both phones are commonly the same person's devices and therefore
      // share a locale, so the guest's saved preference points the wrong way.
      SharedPreferences.setMockInitialValues({
        'my_language': 'de',
        'target_language': 'en',
      });
      final service = SessionService();
      await service.init();
      expect(service.targetLanguage, 'en');

      // The worker mirrors the pair for the guest (see handleJoinRoom).
      service.debugSetSession(
          _session(role: 'guest', sourceLang: 'en', targetLang: 'de'));

      expect(service.sessionTargetLanguage, 'de',
          reason: 'guest must translate into German, not into its own '
              'saved English preference');
    });

    test('both endpoints together cover both directions', () async {
      final host = SessionService();
      final guest = SessionService();
      await host.init();
      await guest.init();

      host.debugSetSession(
          _session(role: 'host', sourceLang: 'de', targetLang: 'en'));
      guest.debugSetSession(
          _session(role: 'guest', sourceLang: 'en', targetLang: 'de'));

      // The whole point of the session: the two endpoints must not translate
      // into the same language, or one speaker is never understood.
      expect(host.sessionTargetLanguage,
          isNot(equals(guest.sessionTargetLanguage)));
      expect(
        {host.sessionTargetLanguage, guest.sessionTargetLanguage},
        {'de', 'en'},
      );
    });
  });
}
