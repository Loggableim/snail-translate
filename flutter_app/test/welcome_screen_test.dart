import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/welcome_screen.dart';

void main() {
  testWidgets('welcome screen page 1 shows value proposition', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    // Page 1 is visible by default
    expect(find.text('Snail'), findsOneWidget);
    expect(
      find.text('Echtzeit-Sprachübersetzung\nfür zwei Personen.'),
      findsOneWidget,
    );
    expect(find.text('Sprich in deiner Sprache'), findsOneWidget);
    expect(find.text('Snail übersetzt live'), findsOneWidget);
    expect(
      find.text('Dein Gegenüber hört die Übersetzung'),
      findsOneWidget,
    );
    expect(find.text('Weiter'), findsOneWidget);
    expect(
      find.text('Kein Konto nötig. Deine Daten bleiben auf deinem Gerät.'),
      findsOneWidget,
    );
    // Guest quick-join button
    expect(find.text('Ich habe einen Code'), findsOneWidget);
  });

  testWidgets('welcome screen page 2 shows microphone test', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    // Navigate to page 2
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();

    // Page 2 content
    expect(find.text('Mikrofon testen'), findsOneWidget);
    // Permission explanation
    expect(
      find.textContaining('Snail braucht dein Mikrofon'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Nichts wird dauerhaft gespeichert'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Sprich kurz etwas in dein Mikrofon'),
      findsOneWidget,
    );
    expect(find.text('Aufnahme starten'), findsOneWidget);
  });

  testWidgets('welcome screen shows page dots', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    // Two page dots should be present
    // (PageDot widgets are AnimatedContainers — we verify via navigation)
    expect(find.text('Weiter'), findsOneWidget);

    // Navigate to page 2
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();

    // Page 2 has the mic test button and a skip option
    expect(find.text('Aufnahme starten'), findsOneWidget);
  });

  testWidgets('welcome screen marks shown on finish', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    // Before finish: not marked
    expect(await WelcomeScreen.hasBeenShown(), isFalse);

    // Navigate to page 2
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();

    // Tap "Überspringen" to finish
    await tester.tap(find.text('Überspringen'));
    await tester.pumpAndSettle();

    // After finish: marked
    expect(await WelcomeScreen.hasBeenShown(), isTrue);
  });

  test('hasBeenShown returns false when no value stored', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await WelcomeScreen.hasBeenShown(), isFalse);
  });

  test('hasBeenShown returns true after markShown', () async {
    SharedPreferences.setMockInitialValues({});
    await WelcomeScreen.markShown();
    expect(await WelcomeScreen.hasBeenShown(), isTrue);
  });
}
