import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import 'api_keys.dart';
import 'error_logger.dart';
import 'retry.dart';
import 'user_identity_service.dart';

/// Manages session lifecycle: create room, join room.
/// Also handles first-run language detection.
class SessionService extends ChangeNotifier {
  static const _supportedLanguages = [
    'de',
    'en',
    'fr',
    'es',
    'it',
    'ja',
    'ko',
    'zh',
    'uk'
  ];

  Session? _currentSession;
  bool _isLoading = false;
  String? _error;
  String _myLanguage = 'de';
  String _targetLanguage = 'en';
  String? _identityId;
  UserIdentityService? _identityService;
  final Future<String?> Function()? _sessionTokenProvider;

  SessionService({Future<String?> Function()? sessionTokenProvider})
      : _sessionTokenProvider = sessionTokenProvider;

  Session? get currentSession => _currentSession;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isInSession => _currentSession != null;
  String get myLanguage => _myLanguage;
  String get targetLanguage => _targetLanguage;

  void setIdentityId(String value) {
    _identityId = value;
  }

  void setIdentityService(UserIdentityService service) {
    _identityService = service;
    if (service.identity?.userId != null) _identityId = service.identity!.userId;
  }

  Future<Map<String, String>> _authHeaders({
    bool json = false,
    String method = 'GET',
    String path = '',
    String body = '',
  }) async {
    final token = await _sessionTokenProvider?.call();
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if ((token == null || token.isEmpty) && ApiKeys.devApiKey.isNotEmpty)
        'X-API-Key': ApiKeys.devApiKey,
      if (_identityId != null && _identityId!.isNotEmpty)
        'X-Snail-Identity': _identityId!,
    };
    final identity = _identityService;
    if (identity?.publicKey != null && identity!.publicKey!.isNotEmpty) {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final payload = '$method\n$path\n$body\n$timestamp';
      final signature = await identity.signDevicePayload(payload);
      if (signature != null && signature.isNotEmpty) {
        headers['X-Snail-Public-Key'] = identity.publicKey!;
        headers['X-Snail-Signature'] = signature;
        headers['X-Snail-Timestamp'] = timestamp;
      }
    }
    return headers;
  }

  Future<Quota?> getQuota() async {
    try {
      final response = await retry(
        () async => withTimeout(
          http.get(
            Uri.parse('${ApiKeys.workerUrl}/api/quota'),
            headers: await _authHeaders(method: 'GET', path: '/api/quota'),
          ),
          const Duration(seconds: 10),
        ),
        maxAttempts: 3,
      );
      if (response.statusCode != 200) return null;
      return Quota.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e, st) {
      ErrorLogger.I
          .log(provider: 'api', context: 'quota.get', error: e, stackTrace: st);
      return null;
    }
  }

  /// Initialize: detect language on first run.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('my_language');
    final savedTarget = prefs.getString('target_language');
    if (savedLang != null && _supportedLanguages.contains(savedLang)) {
      _myLanguage = savedLang;
    } else {
      _myLanguage = detectMyLanguage();
      await prefs.setString('my_language', _myLanguage);
    }
    if (savedTarget != null && _supportedLanguages.contains(savedTarget)) {
      _targetLanguage = savedTarget;
    }
    if (_targetLanguage == _myLanguage) {
      _targetLanguage = _myLanguage == 'en' ? 'de' : 'en';
      await prefs.setString('target_language', _targetLanguage);
    }
    notifyListeners();
  }

  Future<void> setTargetLanguage(String lang) async {
    if (!_supportedLanguages.contains(lang) || lang == _myLanguage) return;
    _targetLanguage = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('target_language', lang);
    notifyListeners();
  }

  /// Detect device language and map to supported languages.
  static String detectMyLanguage() {
    try {
      final locale = Platform.localeName;
      final lang = locale.split('_').first.toLowerCase();
      if (_supportedLanguages.contains(lang)) return lang;
      // Map common variants
      const map = {'pt': 'es', 'nl': 'de', 'pl': 'de', 'ar': 'en'};
      return map[lang] ?? 'en';
    } catch (_) {
      return 'en';
    }
  }

  /// Update my language and persist.
  Future<void> setMyLanguage(String lang) async {
    if (!_supportedLanguages.contains(lang)) return;
    _myLanguage = lang;
    if (_targetLanguage == lang) {
      _targetLanguage = lang == 'en' ? 'de' : 'en';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('my_language', lang);
    await prefs.setString('target_language', _targetLanguage);
    notifyListeners();
  }

  Future<Session?> createRoom({String? inviteeId}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final requestBody = jsonEncode({
        'sourceLang': _myLanguage,
        'targetLang': _targetLanguage,
        if (inviteeId != null && inviteeId.isNotEmpty) 'inviteeId': inviteeId,
      });
      final response = await retry(
        () async => withTimeout(
          http.post(
            Uri.parse('${ApiKeys.workerUrl}/api/rooms'),
            headers: await _authHeaders(
                json: true,
                method: 'POST',
                path: '/api/rooms',
                body: requestBody),
            body: requestBody,
          ),
          const Duration(seconds: 15),
        ),
        maxAttempts: 3,
      );

      if (response.statusCode == 201) {
        _currentSession =
            Session.fromJson(jsonDecode(response.body), role: 'host');
        _isLoading = false;
        notifyListeners();
        return _currentSession;
      } else {
        final data = jsonDecode(response.body);
        _error = data['error'] ?? 'Failed to create room';
      }
    } catch (e, st) {
      _error = 'Network error: $e';
      ErrorLogger.I.log(
          provider: 'api', context: 'session.create', error: e, stackTrace: st);
    }

    _isLoading = false;
    notifyListeners();
    return null;
  }

  Future<Session?> joinRoom(String roomId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Room IDs are created in uppercase. Accept a manually entered code in
      // any case so the fallback is as reliable as scanning the QR code.
      final match = RegExp(r'^snail-([A-Z2-9]{4})$', caseSensitive: false)
          .firstMatch(roomId.trim());
      if (match == null) {
        _error = 'Ungültiger Raumcode';
        _isLoading = false;
        notifyListeners();
        return null;
      }
      // Durable Object names are case-sensitive. Rooms are created as
      // `snail-ABCD`, so only normalize the suffix; uppercasing the prefix
      // turns it into a distinct, non-existent room (`SNAIL-ABCD`).
      final normalizedRoomId = 'snail-${match.group(1)!.toUpperCase()}';
      const requestBody = '';
      final response = await retry(
        () async => withTimeout(
          http.post(
            Uri.parse('${ApiKeys.workerUrl}/api/rooms/$normalizedRoomId/join'),
            headers: await _authHeaders(
                json: true,
                method: 'POST',
                path: '/api/rooms/$normalizedRoomId/join',
                body: requestBody),
            body: requestBody,
          ),
          const Duration(seconds: 15),
        ),
        maxAttempts: 3,
      );

      if (response.statusCode == 200) {
        _currentSession =
            Session.fromJson(jsonDecode(response.body), role: 'guest');
        _isLoading = false;
        notifyListeners();
        return _currentSession;
      } else {
        final data = jsonDecode(response.body);
        _error = data['error'] ?? 'Failed to join room';
      }
    } catch (e, st) {
      _error = 'Network error: $e';
      ErrorLogger.I.log(
          provider: 'api', context: 'session.join', error: e, stackTrace: st);
    }

    _isLoading = false;
    notifyListeners();
    return null;
  }

  /// Gets a short-lived OpenAI Realtime client secret from the Worker. This
  /// is the non-BYOK deployment path; the Worker must own OPENAI_API_KEY.
  Future<String?> fetchOpenAiClientSecret(String targetLanguage) async {
    try {
      final response = await retry(
        () async => withTimeout(
          http.post(
            Uri.parse('${ApiKeys.workerUrl}/api/realtime/client-secret'),
            headers: await _authHeaders(
                json: true,
                method: 'POST',
                path: '/api/realtime/client-secret',
                body: jsonEncode({'targetLanguage': targetLanguage})),
            body: jsonEncode({'targetLanguage': targetLanguage}),
          ),
          const Duration(seconds: 15),
        ),
        maxAttempts: 3,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final value = body['value'] ??
          (body['client_secret'] as Map<String, dynamic>?)?['value'];
      return value is String && value.isNotEmpty ? value : null;
    } catch (e, st) {
      ErrorLogger.I.log(
          provider: 'api',
          context: 'realtime.client-secret',
          error: e,
          stackTrace: st);
      return null;
    }
  }

  void endSession() {
    _currentSession = null;
    _error = null;
    notifyListeners();
  }
}
