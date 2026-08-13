import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/screens/settings_screen.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/audio_policy.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/services/error_logger.dart';

Widget _wrapWithProviders(Widget child, {List<String>? pushedRoutes}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => AudioPolicy()),
      ChangeNotifierProvider(create: (_) => UserIdentityService()),
      ChangeNotifierProvider.value(value: ErrorLogger.I),
    ],
    // Pinned to German: these tests assert on the ARB template strings, not
    // on localization behavior itself.
    child: MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
      onGenerateRoute: (settings) {
        pushedRoutes?.add(settings.name ?? '');
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('route ${settings.name}')),
        );
      },
    ),
  );
}

/// Phone-sized screen including the space a status bar and a navigation bar
/// take away, so "fits without scrolling" means the same as on a device.
void _useScreen(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 800);
  tester.view.padding =
      const FakeViewPadding(top: 24, bottom: 48, left: 0, right: 0);
  addTearDown(tester.view.reset);
}

/// Every section of the settings screen, by the title shown when collapsed.
const _sections = [
  'Meine Sprache',
  'Unterstützte Sprachen',
  'Audio',
  'Meine Identität',
  'Eigener Provider',
  'Fehlerprotokoll',
  'Snail v0.2.0',
];

void main() {
  testWidgets('settings screen lists every section collapsed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    await tester.pumpWidget(_wrapWithProviders(const SettingsScreen()));
    await tester.pumpAndSettle();

    // Six of the seven sections are on screen at once; the app row sits just
    // below the fold, one short scroll away instead of a screen and a half.
    for (final section in _sections.take(6)) {
      final finder = find.text(section);
      expect(finder, findsOneWidget, reason: '"$section" missing');
      expect(tester.getRect(finder).bottom, lessThanOrEqualTo(752.0),
          reason: '"$section" is below the visible area');
    }
    await tester.scrollUntilVisible(find.text(_sections.last), 100);
    expect(find.text(_sections.last), findsOneWidget);

    // Collapsed means the controls themselves are not built yet — the summary
    // line stands in for them.
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('Deutsch → English'), findsOneWidget);
  });

  testWidgets('settings screen shows supported languages section',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    await tester.pumpWidget(_wrapWithProviders(const SettingsScreen()));
    await tester.pumpAndSettle();

    // Section header
    expect(find.text('Unterstützte Sprachen'), findsOneWidget);

    await tester.tap(find.text('Unterstützte Sprachen'));
    await tester.pumpAndSettle();

    // Description text
    expect(
      find.textContaining('Snail übersetzt live zwischen diesen Sprachen'),
      findsOneWidget,
    );

    // ISO codes appear only in the language chips (not in dropdowns)
    for (final code in const [
      'DE',
      'EN',
      'FR',
      'ES',
      'IT',
      'JA',
      'KO',
      'ZH',
      'UK',
    ]) {
      expect(find.text(code), findsOneWidget);
    }

    // Native names appear in both chips and dropdowns — at least one each
    for (final native in const [
      'Deutsch',
      'English',
      'Français',
      'Español',
      'Italiano',
      '日本語',
      '한국어',
      '中文',
      'Українська',
    ]) {
      expect(find.text(native), findsWidgets);
    }
  });

  testWidgets('language section opens both dropdowns', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    await tester.pumpWidget(_wrapWithProviders(const SettingsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Meine Sprache'));
    await tester.pumpAndSettle();

    expect(find.text('Ich spreche'), findsOneWidget);
    expect(find.text('Übersetzen in'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
  });

  testWidgets('audio section shows the profile and the speaker test',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    await tester.pumpWidget(_wrapWithProviders(const SettingsScreen()));
    await tester.pumpAndSettle();

    // The summary names the active profile before the section is opened.
    expect(find.text('Automatisch'), findsOneWidget);

    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();

    expect(find.text('Audio- und Echo-Profil'), findsOneWidget);
    expect(find.text('Lautsprecher testen'), findsOneWidget);
  });

  testWidgets('identity section reaches the profile screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    final pushed = <String>[];
    await tester.pumpWidget(
        _wrapWithProviders(const SettingsScreen(), pushedRoutes: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Meine Identität'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Profil und Nutzung'));
    await tester.pumpAndSettle();

    expect(pushed, ['/profile']);
  });

  testWidgets('provider row reaches the provider settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    final pushed = <String>[];
    await tester.pumpWidget(
        _wrapWithProviders(const SettingsScreen(), pushedRoutes: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Eigener Provider'));
    await tester.pumpAndSettle();

    expect(pushed, ['/provider-settings']);
  });

  testWidgets('error log section summarises an empty log', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester);
    ErrorLogger.I.clearLogs();
    await tester.pumpWidget(_wrapWithProviders(const SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Keine Fehler — alles sauber!'), findsOneWidget);

    await tester.tap(find.text('Fehlerprotokoll'));
    await tester.pumpAndSettle();

    expect(find.text('Fehlerprotokoll anzeigen'), findsOneWidget);
    // Nothing to delete, so the clear entry stays disabled.
    final clear = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Protokoll löschen'));
    expect(clear.enabled, isFalse);
  });
}
