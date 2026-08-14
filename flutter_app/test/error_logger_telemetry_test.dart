import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snail/services/error_logger.dart';

void main() {
  test('diagnostics are opt-in and persist the explicit choice', () async {
    SharedPreferences.setMockInitialValues({});
    final logger = ErrorLogger.I;

    await logger.loadPreferences();
    expect(logger.telemetryEnabled, isFalse);

    await logger.setTelemetryEnabled(true);
    expect(logger.telemetryEnabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('snail_diagnostics_opt_in'), isTrue);

    await logger.setTelemetryEnabled(false);
    expect(prefs.getBool('snail_diagnostics_opt_in'), isFalse);
  });
}
