import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/settings_screen.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/audio_policy.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/services/error_logger.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => AudioPolicy()),
      ChangeNotifierProvider(create: (_) => UserIdentityService()),
      ChangeNotifierProvider.value(value: ErrorLogger.I),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('settings screen shows supported languages section', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_wrapWithProviders(const SettingsScreen()));
    await tester.pumpAndSettle();

    // Section header
    expect(find.text('Unterstützte Sprachen'), findsOneWidget);

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
}
