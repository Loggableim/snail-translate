import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/provider_settings_screen.dart';
import 'package:snail/services/provider_config_service.dart';
import 'package:snail/models/provider_config.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => ProviderConfigService()),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('provider screen shows description for OpenAI', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const ProviderSettingsScreen()),
    );
    await tester.pumpAndSettle();

    // Default provider is ollama — switch to OpenAI
    await tester.tap(find.text('Ollama'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI Realtime-Übersetzung').last);
    await tester.pumpAndSettle();

    // Verify description card appears
    expect(find.text('OpenAI Realtime-Übersetzung'), findsWidgets);
    expect(
      find.textContaining('Cloud · niedrigste Latenz · API-Key nötig'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'OpenAI übersetzt gesprochene Sprache direkt in Echtzeit',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('empfohlene Wahl für Live-Gespräche'),
      findsOneWidget,
    );
    expect(
      find.textContaining('\$0,034 pro Minute Audio'),
      findsOneWidget,
    );
  });

  testWidgets('provider screen shows description for Gemini', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const ProviderSettingsScreen()),
    );
    await tester.pumpAndSettle();

    // Switch to Gemini
    await tester.tap(find.text('Ollama'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini Live (Audio)').last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Cloud · gute Latenz · API-Key nötig'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Google Gemini übersetzt Audio-Streams live'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Google AI Studio'),
      findsOneWidget,
    );
  });

  testWidgets('provider screen shows description for Ollama', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const ProviderSettingsScreen()),
    );
    await tester.pumpAndSettle();

    // Default is Ollama — description should be visible
    expect(
      find.textContaining('Lokal · kein API-Key · höhere Latenz'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Deine Daten verlassen dein Netzwerk nicht'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Nicht empfohlen für Live-Gespräche'),
      findsOneWidget,
    );
  });
}
