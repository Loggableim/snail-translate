import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/screens/qr_host_screen.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/services/user_identity_service.dart';
import 'package:snail/services/error_logger.dart';

Widget _wrapWithProviders(Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SessionService()),
      ChangeNotifierProvider(create: (_) => UserIdentityService()),
      ChangeNotifierProvider.value(value: ErrorLogger.I),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('qr host screen shows loading state while checking audio', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _wrapWithProviders(const QrHostScreen()),
    );
    expect(find.text('Audio wird geprüft …'), findsOneWidget);
  });

  testWidgets('qr host screen shows headset warning when none detected', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.snail.audio/method'),
      (call) async {
        if (call.method == 'isHeadsetConnected') return false;
        return null;
      },
    );

    await tester.pumpWidget(
      _wrapWithProviders(const QrHostScreen()),
    );
    await tester.pumpAndSettle();

    // Headset warning should appear
    expect(
      find.textContaining('Kein Headset erkannt'),
      findsOneWidget,
    );
    expect(
      find.textContaining('empfehlen wir ein Headset'),
      findsOneWidget,
    );
    // Should NOT show "Headset erkannt"
    expect(find.text('Headset erkannt'), findsNothing);
  });

  testWidgets('qr host screen shows headset confirmed when detected', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.snail.audio/method'),
      (call) async {
        if (call.method == 'isHeadsetConnected') return true;
        return null;
      },
    );

    await tester.pumpWidget(
      _wrapWithProviders(const QrHostScreen()),
    );
    await tester.pumpAndSettle();

    // Should show "Headset erkannt"
    expect(find.text('Headset erkannt'), findsOneWidget);
    // Should NOT show the warning
    expect(
      find.textContaining('Kein Headset erkannt'),
      findsNothing,
    );
  });
}
