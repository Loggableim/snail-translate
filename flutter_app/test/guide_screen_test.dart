import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/models/provider_config.dart';
import 'package:snail/screens/guide_screen.dart';
import 'package:snail/services/audio_service.dart';
import 'package:snail/services/provider_config_service.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/theme/app_theme.dart';

/// A config service with a fixed provider, bypassing secure storage.
class _FixedConfigService extends ProviderConfigService {
  _FixedConfigService(this._fixed);
  final ProviderConfig _fixed;

  @override
  ProviderConfig get config => _fixed;
}

Widget _wrap(Widget child, {ProviderConfigService? providerConfig}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => AudioService()),
      // The screen reads the device identity to send it on the websocket
      // upgrade, so the provider must exist in the test tree too.
      ChangeNotifierProvider(create: (_) => UserIdentityService()),
      // Registered as the base type: `context.watch<ProviderConfigService>()`
      // does not resolve a subtype registration.
      ChangeNotifierProvider<ProviderConfigService>(
          create: (_) => providerConfig ?? ProviderConfigService()),
    ],
    child: MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.darkTheme,
      home: child,
    ),
  );
}

void main() {
  setUp(() {
    // The provider config service reads from secure storage; in a widget test
    // that platform channel has no implementation.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  testWidgets('guide setup renders the language picker and start button',
      (tester) async {
    await tester.pumpWidget(_wrap(const GuideScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Zuhör-Modus'), findsOneWidget);
    expect(find.text('Sprachen für Zuhörer'), findsOneWidget);
    // A few of the shared language chips must be offered.
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Français'), findsOneWidget);
    expect(find.text('Zuhör-Modus starten'), findsOneWidget);
  });

  testWidgets('guide setup warns when the provider cannot translate',
      (tester) async {
    // Gemini Live cannot translate text, so the guide pipeline would fail on
    // every turn — the screen must say so instead of starting.
    final config = _FixedConfigService(const ProviderConfig(
      provider: TranslationProvider.geminiLive,
      endpoint: '',
      model: '',
      apiKey: 'key',
    ));
    await tester.pumpWidget(_wrap(const GuideScreen(), providerConfig: config));
    await tester.pumpAndSettle();

    expect(find.textContaining('Gemini Live'), findsOneWidget);
    expect(find.textContaining('nicht übersetzen'), findsOneWidget);
    // The start action must be disabled: the pipeline cannot work on Gemini.
    // `FilledButton.icon` builds a private subclass, so the disabled state is
    // asserted through the semantics node instead of a widget type.
    final semantics = tester.getSemantics(find.text('Zuhör-Modus starten'));
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);
  });

  testWidgets('guide setup requires at least one listener language',
      (tester) async {
    await tester.pumpWidget(_wrap(const GuideScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zuhör-Modus starten'));
    await tester.pumpAndSettle();

    expect(find.text('Wähle mindestens eine Sprache für die Zuhörer.'),
        findsOneWidget);
  });
}
