import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/screens/join_screen.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/contact_service.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/services/error_logger.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => ContactService()),
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
    ),
  );
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.steenbock.mobile_scanner/scanner/method'),
      (call) async => null,
    );
  });

  testWidgets('join screen renders without error', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const JoinScreen()),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Session beitreten'), findsOneWidget);
  });

  testWidgets('join screen shows manual code entry field', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const JoinScreen()),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Oder Code eingeben:'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Beitreten'), findsOneWidget);
  });
}
