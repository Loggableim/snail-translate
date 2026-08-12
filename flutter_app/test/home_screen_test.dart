import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/home_screen.dart';
import 'package:snail/theme/app_theme.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/services/error_logger.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => UserIdentityService()),
      ChangeNotifierProvider.value(value: ErrorLogger.I),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('home screen shows code entry quick action', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const HomeScreen()),
    );
    await tester.pumpAndSettle();

    // Should show "Code eingeben" quick action
    expect(find.text('Code eingeben'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);
  });

  testWidgets('home screen code entry opens dialog', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const HomeScreen()),
    );
    await tester.pumpAndSettle();

    // Tap the "Code eingeben" quick action
    await tester.tap(find.text('Code eingeben'));
    await tester.pumpAndSettle();

    // Dialog should appear
    expect(find.text('Session-Code eingeben'), findsOneWidget);
    expect(find.text('Gib den Session-Code deines Gesprächspartners ein.'),
        findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);
    // "Beitreten" appears in both dialog and quick action — check dialog exists
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });
}
