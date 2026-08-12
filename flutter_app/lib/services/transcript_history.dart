import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single transcript entry (original + translation).
class TranscriptEntry {
  final String id;
  final String sessionId;
  final DateTime timestamp;
  final String sourceLang;
  final String targetLang;
  final String originalText;
  final String translatedText;
  final String provider;

  const TranscriptEntry({
    required this.id,
    required this.sessionId,
    required this.timestamp,
    required this.sourceLang,
    required this.targetLang,
    required this.originalText,
    required this.translatedText,
    this.provider = 'unbekannt',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'timestamp': timestamp.toIso8601String(),
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'originalText': originalText,
        'translatedText': translatedText,
        'provider': provider,
      };

  factory TranscriptEntry.fromJson(Map<String, dynamic> json) =>
      TranscriptEntry(
        id: json['id'] as String,
        sessionId: json['sessionId'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        sourceLang: json['sourceLang'] as String,
        targetLang: json['targetLang'] as String,
        originalText: json['originalText'] as String,
        translatedText: json['translatedText'] as String,
        provider: json['provider'] as String? ?? 'unbekannt',
      );
}

/// Manages transcript history with SharedPreferences persistence.
class TranscriptHistory extends ChangeNotifier {
  static const _key = 'transcript_history';
  static const _maxEntries = 500;
  static const _secureStorage = FlutterSecureStorage();

  List<TranscriptEntry> _entries = [];
  List<TranscriptEntry> get entries => List.unmodifiable(_entries);

  /// Load history from storage.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // New installs keep transcript content in Android Keystore-backed
    // encrypted storage. Read the old preferences value only once so users
    // upgrading from the prototype do not lose their local history.
    var raw = await _secureStorage.read(key: _key);
    final legacyRaw = prefs.getString(_key);
    if (raw == null && legacyRaw != null) {
      raw = legacyRaw;
      await _secureStorage.write(key: _key, value: legacyRaw);
      await prefs.remove(_key);
    }
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _entries = list
            .map((e) => TranscriptEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _entries = [];
      }
    }
    notifyListeners();
  }

  /// Add a new entry and persist.
  Future<void> addEntry({
    required String sessionId,
    required String sourceLang,
    required String targetLang,
    required String originalText,
    required String translatedText,
    String provider = 'unbekannt',
  }) async {
    final entry = TranscriptEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sessionId: sessionId,
      timestamp: DateTime.now(),
      sourceLang: sourceLang,
      targetLang: targetLang,
      originalText: originalText,
      translatedText: translatedText,
      provider: provider,
    );

    _entries.insert(0, entry);

    // Trim to max
    if (_entries.length > _maxEntries) {
      _entries = _entries.sublist(0, _maxEntries);
    }

    await _persist();
    notifyListeners();
  }

  /// Get entries for a specific session.
  List<TranscriptEntry> getEntriesForSession(String sessionId) {
    return _entries.where((e) => e.sessionId == sessionId).toList();
  }

  /// Clear all history.
  Future<void> clearHistory() async {
    _entries.clear();
    await _persist();
    notifyListeners();
  }

  /// Delete a single entry.
  Future<void> deleteEntry(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _secureStorage.write(
      key: _key,
      value: jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }
}
