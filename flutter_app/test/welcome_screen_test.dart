import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/welcome_screen.dart';
import 'package:snail/services/session_service.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('welcome screen page 1 shows value proposition', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const WelcomeScreen()),
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
    // Language confirmation
    expect(find.text('Deine Sprache'), findsOneWidget);
    expect(find.text('automatisch erkannt'), findsOneWidget);
    expect(find.text('Ändern'), findsOneWidget);
    // Guest quick-join button
    expect(find.text('Ich habe einen Code'), findsOneWidget);
    // Privacy note
    expect(
      find.text('Kein Konto nötig. Deine Daten bleiben auf deinem Gerät.'),
      findsOneWidget,
    );
  });

  testWidgets('welcome screen page 2 shows microphone test', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    // Jump to page 2 via PageController
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(1);
    await tester.pumpAndSettle();

    // Page 2 content
    expect(find.text('Mikrofon testen'), findsOneWidget);
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
      _wrapWithProviders(const WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    // Jump to page 2
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(1);
    await tester.pumpAndSettle();

    expect(find.text('Aufnahme starten'), findsOneWidget);
  });

  testWidgets('welcome screen marks shown on finish', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const WelcomeScreen()),
    );
    await tester.pumpAndSettle();

    expect(await WelcomeScreen.hasBeenShown(), isFalse);

    // Jump to page 2
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(1);
    await tester.pumpAndSettle();

    // Tap "Überspringen" to finish
    await tester.tap(find.text('Überspringen'));
    await tester.pumpAndSettle();

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
