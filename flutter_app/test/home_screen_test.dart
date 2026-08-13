import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/screens/home_screen.dart';
import 'package:snail/theme/app_theme.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/services/error_logger.dart';

Widget _wrapWithProviders(Widget child,
    {List<String>? pushedRoutes, double textScale = 1.0}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => UserIdentityService()),
      ChangeNotifierProvider.value(value: ErrorLogger.I),
    ],
    // Pinned to German: these tests assert on the ARB template strings, not
    // on localization behavior itself.
    child: MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.darkTheme,
      home: child,
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: navigator!,
      ),
      // Records where the dashboard tiles navigate to instead of building the
      // real screens (they need services this test does not provide).
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

/// Puts the test view on a phone-sized screen including the space a status bar
/// and a navigation bar take away, so "fits without scrolling" means the same
/// thing here as on a device.
void _useScreen(WidgetTester tester, double width, double height) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  tester.view.padding =
      const FakeViewPadding(top: 24, bottom: 48, left: 0, right: 0);
  addTearDown(tester.view.reset);
}

/// Every destination the home screen offers, with the label the user sees.
const _destinations = <String, String>{
  'Schnellübersetzer': '/standalone',
  'Session starten': '/qr-host',
  'Beitreten': '/join',
  'Messenger': '/chat',
  'Kontakte': '/contacts',
  'App teilen': '/app-share',
  'Verlauf': '/history',
};

void main() {
  testWidgets('home screen shows code entry quick action', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 360, 800);
    await tester.pumpWidget(_wrapWithProviders(const HomeScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Code eingeben'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);
  });

  testWidgets('home screen code entry opens dialog', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 360, 800);
    await tester.pumpWidget(_wrapWithProviders(const HomeScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Code eingeben'));
    await tester.pumpAndSettle();

    expect(find.text('Session-Code eingeben'), findsOneWidget);
    expect(find.text('Gib den Session-Code deines Gesprächspartners ein.'),
        findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);
    // "Beitreten" appears in both dialog and quick action — check dialog exists
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });

  for (final size in const [Size(360, 800), Size(411, 891)]) {
    testWidgets(
        'all ten entry points fit on ${size.width.toInt()}x${size.height.toInt()} without scrolling',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      _useScreen(tester, size.width, size.height);
      await tester.pumpWidget(_wrapWithProviders(const HomeScreen()));
      await tester.pumpAndSettle();

      // Eight tiles in the body …
      for (final label in [..._destinations.keys, 'Code eingeben']) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '"$label" is missing');
        final rect = tester.getRect(finder);
        expect(rect.top >= 0 && rect.bottom <= size.height, isTrue,
            reason: '"$label" is off screen: $rect');
      }
      // … plus theme toggle and settings in the app bar.
      expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      // Nothing scrolls: the dashboard is laid out to the available height.
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(Scrollable), findsNothing);
    });
  }

  for (final entry in _destinations.entries) {
    testWidgets('tile "${entry.key}" opens ${entry.value}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pushed = <String>[];
      _useScreen(tester, 360, 800);
      await tester.pumpWidget(
          _wrapWithProviders(const HomeScreen(), pushedRoutes: pushed));
      await tester.pumpAndSettle();

      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(pushed, [entry.value]);
    });
  }

  testWidgets('settings icon opens the settings route', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final pushed = <String>[];
    _useScreen(tester, 360, 800);
    await tester
        .pumpWidget(_wrapWithProviders(const HomeScreen(), pushedRoutes: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    expect(pushed, ['/settings']);
  });

  testWidgets('theme toggle switches the theme', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 360, 800);
    await tester.pumpWidget(_wrapWithProviders(const HomeScreen()));
    await tester.pumpAndSettle();

    // Starts dark, so the button offers light mode.
    expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.light_mode_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
  });

  testWidgets('landscape keeps every entry point on one screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 800, 360);
    await tester.pumpWidget(_wrapWithProviders(const HomeScreen()));
    await tester.pumpAndSettle();

    for (final label in [..._destinations.keys, 'Code eingeben']) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is missing');
    }
    expect(find.byType(Scrollable), findsNothing);
  });

  testWidgets('doubled system font still fits without scrolling',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 360, 800);
    await tester
        .pumpWidget(_wrapWithProviders(const HomeScreen(), textScale: 2.0));
    await tester.pumpAndSettle();

    for (final label in [..._destinations.keys, 'Code eingeben']) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is missing');
    }
    expect(find.byType(Scrollable), findsNothing);
  });

  testWidgets('extreme system font falls back to a scrollable dashboard',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 360, 800);
    await tester
        .pumpWidget(_wrapWithProviders(const HomeScreen(), textScale: 3.0));
    await tester.pumpAndSettle();

    // The emergency case: tiles keep their readable minimum height and the
    // dashboard scrolls instead — every destination is still there.
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    for (final label in [..._destinations.keys, 'Code eingeben']) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is missing');
    }
  });

  testWidgets('split screen height falls back to a scrollable dashboard',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _useScreen(tester, 360, 420);
    await tester.pumpWidget(_wrapWithProviders(const HomeScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    for (final label in [..._destinations.keys, 'Code eingeben']) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is missing');
    }
  });
}
