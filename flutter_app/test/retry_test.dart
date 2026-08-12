import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/retry.dart';

void main() {
  group('retry', () {
    test('succeeds on first attempt', () async {
      var calls = 0;
      final result = await retry<int>(() async {
        calls++;
        return 42;
      });
      expect(result, 42);
      expect(calls, 1);
    });

    test('retries on failure and succeeds', () async {
      var calls = 0;
      final result = await retry<int>(
        () async {
          calls++;
          if (calls < 3) throw Exception('fail $calls');
          return 99;
        },
        maxAttempts: 3,
        baseDelay: const Duration(milliseconds: 1),
      );
      expect(result, 99);
      expect(calls, 3);
    });

    test('throws after max attempts', () async {
      var calls = 0;
      await expectLater(
        retry<int>(
          () async {
            calls++;
            throw Exception('always fail');
          },
          maxAttempts: 3,
          baseDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<Exception>()),
      );
      expect(calls, 3);
    });

    test('respects retryIf filter', () async {
      var calls = 0;
      await expectLater(
        retry<int>(
          () async {
            calls++;
            throw ArgumentError('bad arg');
          },
          maxAttempts: 3,
          baseDelay: const Duration(milliseconds: 1),
          retryIf: (e) => e is TimeoutException, // only retry timeouts
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(calls, 1); // no retry
    });
  });

  group('withTimeout', () {
    test('returns value when future completes in time', () async {
      final result = await withTimeout<int>(
        Future.value(42),
        const Duration(seconds: 1),
      );
      expect(result, 42);
    });

    test('throws TimeoutException when future is too slow', () async {
      await expectLater(
        withTimeout<int>(
          Future.delayed(const Duration(seconds: 10), () => 42),
          const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
