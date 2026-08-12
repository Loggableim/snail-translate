import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Structured error logging for Snail.
///
/// Usage:
///   ErrorLogger.I.log(provider: "groq", context: "stt.transcribe", error: e);
///   final logs = ErrorLogger.I.getLogs();
class ErrorLogger extends ChangeNotifier {
  ErrorLogger._();
  static final ErrorLogger I = ErrorLogger._();

  final List<ErrorEntry> _logs = [];
  static const int _maxEntries = 200;

  /// Log an error with provider, context, and optional stack trace.
  void log({
    required String provider,
    required String context,
    required Object error,
    StackTrace? stackTrace,
  }) {
    final safeMessage = _redact(error.toString());
    final safeStack = _redact(stackTrace?.toString() ?? "");
    _logs.insert(
      0,
      ErrorEntry(
        timestamp: DateTime.now(),
        provider: provider,
        context: context,
        message: safeMessage,
        stackTrace: safeStack,
      ),
    );
    if (_logs.length > _maxEntries) {
      _logs.removeRange(_maxEntries, _logs.length);
    }
    notifyListeners();
    debugPrint("[Snail:Error] $provider/$context: $safeMessage");
  }

  static String _redact(String value) => value
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._-]+', caseSensitive: false),
          'Bearer [REDACTED]')
      .replaceAll(RegExp(r'(sk-fish-|sk-proj-|gsk_)[A-Za-z0-9._-]+'),
          '[REDACTED_KEY]');

  /// Get all logged errors (newest first).
  List<ErrorEntry> getLogs() => List.unmodifiable(_logs);

  /// Clear all logs.
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// Export logs as JSON string.
  String exportLogs() {
    return const JsonEncoder.withIndent("  ")
        .convert(_logs.map((e) => e.toJson()).toList());
  }
}

/// A single error log entry.
class ErrorEntry {
  final DateTime timestamp;
  final String provider;
  final String context;
  final String message;
  final String stackTrace;

  const ErrorEntry({
    required this.timestamp,
    required this.provider,
    required this.context,
    required this.message,
    required this.stackTrace,
  });

  Map<String, dynamic> toJson() => {
        "timestamp": timestamp.toIso8601String(),
        "provider": provider,
        "context": context,
        "message": message,
        "stackTrace": stackTrace,
      };
}
