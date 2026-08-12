import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/welcome_screen.dart';

void main() {
  testWidgets('welcome screen renders core value proposition', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: WelcomeScreen(),
      ),
    );

    // Headline
    expect(find.text('Snail'), findsOneWidget);
    // Core value proposition
    expect(
      find.text('Echtzeit-Sprachübersetzung\nfür zwei Personen.'),
      findsOneWidget,
    );
    // Feature rows
    expect(find.text('Sprich in deiner Sprache'), findsOneWidget);
    expect(find.text('Snail übersetzt live'), findsOneWidget);
    expect(
      find.text('Dein Gegenüber hört die Übersetzung'),
      findsOneWidget,
    );
    // CTA
    expect(find.text('Los geht\'s'), findsOneWidget);
    // Privacy note
    expect(
      find.text('Kein Konto nötig. Deine Daten bleiben auf deinem Gerät.'),
      findsOneWidget,
    );
  });

  testWidgets('welcome screen marks shown on CTA tap', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: WelcomeScreen(),
      ),
    );

    // Before tap: not marked
    expect(await WelcomeScreen.hasBeenShown(), isFalse);

    await tester.tap(find.text('Los geht\'s'));
    await tester.pumpAndSettle();

    // After tap: marked
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
