import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/welcome_screen.dart';
import 'package:snail/services/provider_config_service.dart';
import 'package:snail/services/session_service.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => ProviderConfigService()),
    ],
    child: MaterialApp(home: child),
  );
}

Future<void> _pumpWelcome(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(_wrapWithProviders(const WelcomeScreen()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('welcome starts with language selection', (tester) async {
    await _pumpWelcome(tester);
    expect(find.text('Snail'), findsOneWidget);
    expect(find.textContaining('Hello, choose your language.'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNWidgets(9));
  });

  testWidgets('welcome second page shows Fish Audio key setup', (tester) async {
    await _pumpWelcome(tester);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(1);
    await tester.pumpAndSettle();
    expect(find.text('Fish Audio einrichten'), findsOneWidget);
    expect(find.text('Fish Audio API-Key'), findsOneWidget);
    expect(find.text('Andere API / Provider verwenden'), findsOneWidget);
  });

  testWidgets('welcome microphone page renders', (tester) async {
    await _pumpWelcome(tester);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(3);
    await tester.pumpAndSettle();
    expect(find.text('Mikrofon testen'), findsOneWidget);
    expect(find.text('Aufnahme starten'), findsOneWidget);
  });

  testWidgets('welcome tutorial page renders', (tester) async {
    await _pumpWelcome(tester);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(4);
    await tester.pumpAndSettle();
    expect(find.text('So funktioniert Snail'), findsOneWidget);
  });

  testWidgets('welcome marks shown on finish', (tester) async {
    await _pumpWelcome(tester);
    expect(await WelcomeScreen.hasBeenShown(), isFalse);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(3);
    await tester.pumpAndSettle();
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
