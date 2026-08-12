import 'dart:async';
import 'dart:math';

/// Retry a function with exponential backoff and a maximum number of attempts.
///
/// [fn] is called at most [maxAttempts] times. The first retry waits
/// [baseDelay], the second 2×[baseDelay], the third 4×[baseDelay], etc.
/// If all attempts fail, the last exception is rethrown.
///
/// [retryIf] can filter which exceptions trigger a retry. By default all
/// exceptions trigger a retry.
Future<T> retry<T>(
  Future<T> Function() fn, {
  int maxAttempts = 3,
  Duration baseDelay = const Duration(milliseconds: 500),
  bool Function(Object)? retryIf,
}) async {
  var attempt = 0;
  while (true) {
    attempt++;
    try {
      return await fn();
    } catch (e) {
      if (attempt >= maxAttempts) rethrow;
      if (retryIf != null && !retryIf(e)) rethrow;
      final delay = baseDelay * pow(2, attempt - 1);
      await Future.delayed(delay);
    }
  }
}

/// Wraps a [Future] with a timeout. If the future does not complete within
/// [timeout], a [TimeoutException] is thrown.
Future<T> withTimeout<T>(
  Future<T> future,
  Duration timeout,
) {
  return future.timeout(timeout);
}
