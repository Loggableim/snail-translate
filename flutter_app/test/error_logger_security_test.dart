import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/error_logger.dart';

void main() {
  test('error logger redacts provider secrets', () {
    final logger = ErrorLogger.I;
    logger.clearLogs();
    logger.log(
      provider: 'fishAudio',
      context: 'test',
      error: StateError(
          'Authorization: Bearer sk-fish-secret-value sk-proj-secret-value'),
    );

    final entry = logger.getLogs().single;
    expect(entry.message, isNot(contains('sk-fish-secret-value')));
    expect(entry.message, isNot(contains('sk-proj-secret-value')));
    expect(entry.message, contains('[REDACTED]'));
    logger.clearLogs();
  });

  test('redacts Google, Telegram, query and URL credentials', () {
    final logger = ErrorLogger.I;
    logger.clearLogs();
    logger.log(
      provider: 'security',
      context: 'test',
      error: StateError(
        'AIzaSyA12345678901234567890123456789012 '
        'bot123456:telegram-secret-token-value '
        'wss://user:password@example.invalid/ws?key=gemini-secret&token=session-secret',
      ),
    );

    final message = logger.getLogs().single.message;
    expect(message, isNot(contains('AIzaSyA12345678901234567890123456789012')));
    expect(message, isNot(contains('telegram-secret-token-value')));
    expect(message, isNot(contains('gemini-secret')));
    expect(message, isNot(contains('session-secret')));
    expect(message, isNot(contains('user:password')));
    logger.clearLogs();
  });

  test('redacts secrets before deriving an opt-in telemetry code', () {
    final code = ErrorLogger.errorCodeForTesting(
      'AIzaSyA12345678901234567890123456789012',
    );
    expect(code, isNot(contains('AIza')));
    expect(code, contains('REDACTED_KEY'));
  });
}
