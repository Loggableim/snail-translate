import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_keys.dart';

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
  static const _telemetryKey = 'snail_diagnostics_opt_in';
  bool _telemetryEnabled = false;

  bool get telemetryEnabled => _telemetryEnabled;

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _telemetryEnabled = prefs.getBool(_telemetryKey) ?? false;
    notifyListeners();
  }

  Future<void> setTelemetryEnabled(bool enabled) async {
    _telemetryEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_telemetryKey, enabled);
  }

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
    if (_telemetryEnabled) {
      unawaited(_sendTelemetry(provider: provider, context: context, error: error));
    }
  }

  Future<void> _sendTelemetry({
    required String provider,
    required String context,
    required Object error,
  }) async {
    try {
      await http.post(
        Uri.parse('${ApiKeys.workerUrl}/api/telemetry'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'provider': provider,
          'context': context,
          'code': _errorCode(error),
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Diagnostics must never affect the provider or session path.
    }
  }

  static String _errorCode(Object error) {
    final value = _redact(error.toString().split(':').first.trim());
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    if (sanitized.isEmpty) return 'unknown';
    return sanitized.substring(0, sanitized.length.clamp(1, 96));
  }

  @visibleForTesting
  static String errorCodeForTesting(Object error) => _errorCode(error);

  static String _redact(String value) => value
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._-]+', caseSensitive: false),
          'Bearer [REDACTED]')
      .replaceAll(RegExp(r'(sk-fish-|sk-proj-|gsk_)[A-Za-z0-9._-]+'),
          '[REDACTED_KEY]')
      .replaceAll(RegExp(r'AIza[0-9A-Za-z_-]{35}'), '[REDACTED_KEY]')
      .replaceAll(RegExp(r'bot[0-9]+:[A-Za-z0-9_-]{20,}'), '[REDACTED_TOKEN]')
      .replaceAll(
          RegExp(r'([?&](?:key|token)=)[^&#\s]+', caseSensitive: false),
          '[REDACTED_QUERY]')
      .replaceAll(
          RegExp(r'((?:https?|wss)://)([^/@\s:]+):([^/@\s]+)@', caseSensitive: false),
          '[REDACTED_URL]');

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
