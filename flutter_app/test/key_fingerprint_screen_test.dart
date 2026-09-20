import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/screens/key_fingerprint_screen.dart';
import 'package:snail/services/audio_service.dart';
import 'package:snail/services/key_fingerprint.dart';
import 'package:snail/theme/app_theme.dart';

/// The safety number is the only defence against a relay that swaps keys, so
/// the screen must show it clearly and say what a mismatch means.
void main() {
  Widget wrap(AudioService audio) {
    return ChangeNotifierProvider<AudioService>.value(
      value: audio,
      child: MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.darkTheme,
        home: const KeyFingerprintScreen(),
      ),
    );
  }

  Future<KeyFingerprint> fingerprintFor(List<int> secret) =>
      KeyFingerprint.fromSharedSecret(secret);

  testWidgets('explains that no peer is connected yet', (tester) async {
    await tester.pumpWidget(wrap(AudioService()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Noch kein Gesprächspartner'), findsOneWidget);
    // Nothing to compare, so the number and the checklist stay hidden.
    expect(find.textContaining('Vergleicht diese Nummer'), findsNothing);
    expect(find.textContaining('Unterschiedlich'), findsNothing);
  });

  testWidgets('shows the safety number in twelve groups', (tester) async {
    final audio = AudioService();
    final fingerprint =
        await fingerprintFor(List<int>.generate(32, (index) => index + 1));
    audio.keyFingerprintForTest = fingerprint;

    await tester.pumpWidget(wrap(audio));
    await tester.pumpAndSettle();

    final groups = fingerprint.digits.split(' ');
    expect(groups, hasLength(12));
    for (final group in groups) {
      expect(find.text(group), findsOneWidget);
    }
  });

  testWidgets('states what matching and differing numbers mean',
      (tester) async {
    final audio = AudioService();
    audio.keyFingerprintForTest =
        await fingerprintFor(List<int>.generate(32, (index) => index + 2));

    await tester.pumpWidget(wrap(audio));
    await tester.pumpAndSettle();

    expect(find.textContaining('Gleich:'), findsOneWidget);
    expect(find.textContaining('Unterschiedlich:'), findsOneWidget);
    expect(find.textContaining('Nicht'), findsNothing);
  });

  testWidgets('offers to copy the number', (tester) async {
    final audio = AudioService();
    audio.keyFingerprintForTest =
        await fingerprintFor(List<int>.generate(32, (index) => index + 3));

    await tester.pumpWidget(wrap(audio));
    await tester.pumpAndSettle();

    expect(find.text('Nummer kopieren'), findsOneWidget);
  });

  testWidgets('two devices with the same secret show the same number',
      (tester) async {
    // This is the property the whole screen exists for: both sides derive the
    // same value, so a comparison is meaningful.
    final secret = List<int>.generate(32, (index) => index + 4);
    final alice = AudioService()..keyFingerprintForTest =
        await fingerprintFor(secret);
    final bob = AudioService()..keyFingerprintForTest =
        await fingerprintFor(secret);

    expect(alice.keyFingerprint!.digits, bob.keyFingerprint!.digits);
  });
}
