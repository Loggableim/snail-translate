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
}
