/// Base class for all Snail-specific errors.
///
/// Replaces free-form strings and generic exceptions with typed errors
/// that carry structured context for logging and user-facing messages.
abstract class SnailError implements Exception {
  /// Human-readable message for developers/logs.
  final String message;

  /// Optional underlying cause.
  final Object? cause;

  /// Optional stack trace.
  final StackTrace? stackTrace;

  const SnailError(this.message, {this.cause, this.stackTrace});

  /// User-facing message (may differ from technical [message]).
  String get userMessage => message;

  @override
  String toString() => '$runtimeType: $message';
}

// ── Auth errors ──────────────────────────────────────────────────────

class AuthError extends SnailError {
  const AuthError(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => 'Authentifizierungsfehler';
}

class InvalidTokenError extends AuthError {
  const InvalidTokenError({super.cause, super.stackTrace})
      : super('Invalid or expired session token');
}

// ── Network errors ───────────────────────────────────────────────────

class NetworkError extends SnailError {
  const NetworkError(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => 'Netzwerkfehler';
}

class ConnectionFailedError extends NetworkError {
  const ConnectionFailedError({super.cause, super.stackTrace})
      : super('Failed to establish connection');
}

class ConnectionTimeoutError extends NetworkError {
  const ConnectionTimeoutError({super.cause, super.stackTrace})
      : super('Connection timed out');
}

// ── Provider errors ──────────────────────────────────────────────────

class ProviderError extends SnailError {
  final String provider;

  const ProviderError(this.provider, super.message,
      {super.cause, super.stackTrace});

  @override
  String get userMessage => 'Provider-Fehler ($provider)';
}

class ProviderKeyMissingError extends ProviderError {
  ProviderKeyMissingError(String provider, {super.cause, super.stackTrace})
      : super(provider, 'API key is missing for $provider');
}

class ProviderKeyInvalidError extends ProviderError {
  ProviderKeyInvalidError(String provider, {super.cause, super.stackTrace})
      : super(provider, 'API key is invalid for $provider');
}

class ProviderRateLimitError extends ProviderError {
  ProviderRateLimitError(String provider, {super.cause, super.stackTrace})
      : super(provider, 'Rate limit exceeded for $provider');
}

// ── Audio errors ──────────────────────────────────────────────────────

class AudioError extends SnailError {
  const AudioError(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => 'Audio-Fehler';
}

class MicrophonePermissionError extends AudioError {
  const MicrophonePermissionError({super.cause, super.stackTrace})
      : super('Microphone permission denied');
}

class AudioCaptureError extends AudioError {
  const AudioCaptureError({super.cause, super.stackTrace})
      : super('Failed to start audio capture');
}

class AudioPlaybackError extends AudioError {
  const AudioPlaybackError({super.cause, super.stackTrace})
      : super('Failed to play audio');
}

// ── Session errors ───────────────────────────────────────────────────

class SessionError extends SnailError {
  const SessionError(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => 'Session-Fehler';
}

class SessionNotFoundError extends SessionError {
  const SessionNotFoundError({super.cause, super.stackTrace})
      : super('Session not found');
}

class SessionExpiredError extends SessionError {
  const SessionExpiredError({super.cause, super.stackTrace})
      : super('Session has expired');
}

// ── Validation errors ─────────────────────────────────────────────────

class ValidationError extends SnailError {
  const ValidationError(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => message;
}

class MessageTooLongError extends ValidationError {
  MessageTooLongError(int maxLength, {super.cause, super.stackTrace})
      : super('Message exceeds maximum length of $maxLength characters');
}

class InvalidMessageError extends ValidationError {
  const InvalidMessageError(super.message, {super.cause, super.stackTrace});
}
