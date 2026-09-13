import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import '../l10n/app_localizations.dart';
import 'api_keys.dart';
import 'error_logger.dart';
import 'retry.dart';
import 'user_identity_service.dart';

enum SessionFailureCode {
  invalidRoomCode,
  roomNotFound,
  rateLimited,
  network,
  requestFailed,
}

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
    'uk',
    'ar',
    'pt',
    'ru',
    'nl',
    'tr',
    'hi',
    'vi',
    'pl',
    'sv'
  ];

  Session? _currentSession;
  bool _isLoading = false;
  String? _error;
  SessionFailureCode? _errorCode;
  String _myLanguage = 'de';
  String _targetLanguage = 'en';
  String? _identityId;
  UserIdentityService? _identityService;
  final Future<String?> Function()? _sessionTokenProvider;
  final http.Client _httpClient;
  final Duration _requestTimeout;

  SessionService({
    Future<String?> Function()? sessionTokenProvider,
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _sessionTokenProvider = sessionTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _requestTimeout = requestTimeout;

  Session? get currentSession => _currentSession;
  bool get isLoading => _isLoading;
  String? get error => _error;
  SessionFailureCode? get errorCode => _errorCode;

  String localizedError(AppLocalizations l10n) => switch (_errorCode) {
        SessionFailureCode.invalidRoomCode => l10n.sessionInvalidCode,
        SessionFailureCode.roomNotFound => l10n.sessionRoomNotFound,
        SessionFailureCode.rateLimited => l10n.sessionRateLimited,
        SessionFailureCode.network => l10n.homeJoinFailed,
        SessionFailureCode.requestFailed => l10n.homeJoinFailed,
        null => l10n.homeJoinFailed,
      };
  bool get isInSession => _currentSession != null;
  String get myLanguage => _myLanguage;
  String get targetLanguage => _targetLanguage;

  /// Returns a fresh identity token when the app was configured with an
  /// identity provider. A missing provider is intentional in device-auth
  /// development mode and returns null.
  Future<String?> refreshSessionToken() async => _sessionTokenProvider?.call();

  /// Language this device must translate its own microphone into.
  ///
  /// The worker mirrors the negotiated pair for the guest, so a joined
  /// session already carries the correct per-endpoint direction. Falling back
  /// to [targetLanguage] here would use this device's saved preference
  /// instead: when both phones share a locale — the common case when one
  /// person hands the second device to the other — both would translate into
  /// the same language and one direction of the conversation would silently
  /// produce no translation at all.
  String get sessionTargetLanguage =>
      _currentSession?.targetLang ?? _targetLanguage;

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  /// Installs a session without performing the network handshake, so the
  /// per-endpoint language direction can be tested without a live worker.
  @visibleForTesting
  void debugSetSession(Session? session) {
    _currentSession = session;
    notifyListeners();
  }

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
          _httpClient.get(
            Uri.parse('${ApiKeys.workerUrl}/api/quota'),
            headers: await _authHeaders(method: 'GET', path: '/api/quota'),
          ),
          _requestTimeout,
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
      return 'en';
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
    _errorCode = null;
    notifyListeners();

    try {
      final requestBody = jsonEncode({
        'sourceLang': _myLanguage,
        'targetLang': _targetLanguage,
        if (inviteeId != null && inviteeId.isNotEmpty) 'inviteeId': inviteeId,
      });
      // Room creation is not idempotent: a timeout may occur after the
      // Worker has already allocated the room. Do not repeat this POST.
      final response = await withTimeout(
        _httpClient.post(
          Uri.parse('${ApiKeys.workerUrl}/api/rooms'),
          headers: await _authHeaders(
              json: true,
              method: 'POST',
              path: '/api/rooms',
              body: requestBody),
          body: requestBody,
        ),
        _requestTimeout,
      );

      if (response.statusCode == 201) {
        _currentSession =
            Session.fromJson(jsonDecode(response.body), role: 'host');
        _isLoading = false;
        notifyListeners();
        return _currentSession;
      } else {
        _errorCode = response.statusCode == 429
            ? SessionFailureCode.rateLimited
            : SessionFailureCode.requestFailed;
        _error = 'session_request_failed_${response.statusCode}';
      }
    } catch (e, st) {
      _errorCode = SessionFailureCode.network;
      _error = 'session_network';
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
    _errorCode = null;
    notifyListeners();

    try {
      // Room IDs are created in uppercase. Accept a manually entered code in
      // any case so the fallback is as reliable as scanning the QR code.
      final match = RegExp(r'^snail-([A-HJ-NP-Z2-9]{8})$', caseSensitive: false)
          .firstMatch(roomId.trim());
      if (match == null) {
        _errorCode = SessionFailureCode.invalidRoomCode;
        _error = 'session_invalid_room_code';
        _isLoading = false;
        notifyListeners();
        return null;
      }
      // Durable Object names are case-sensitive. Rooms are created as
      // `snail-AAYV2B7C`, so only normalize the suffix; uppercasing the prefix
      // turns it into a distinct, non-existent room (`SNAIL-ABCD`).
      final normalizedRoomId = 'snail-${match.group(1)!.toUpperCase()}';
      const requestBody = '';
      // Joining also creates a short-lived session token. A timeout can occur
      // after the Worker has issued it, so repeating this POST is unsafe.
      final response = await withTimeout(
        _httpClient.post(
          Uri.parse('${ApiKeys.workerUrl}/api/rooms/$normalizedRoomId/join'),
          headers: await _authHeaders(
              json: true,
              method: 'POST',
              path: '/api/rooms/$normalizedRoomId/join',
              body: requestBody),
          body: requestBody,
        ),
        _requestTimeout,
      );

      if (response.statusCode == 200) {
        _currentSession =
            Session.fromJson(jsonDecode(response.body), role: 'guest');
        _isLoading = false;
        notifyListeners();
        return _currentSession;
      } else {
        // Map the status codes the Worker actually returns so the user sees
        // why a join failed instead of a generic "failed".
        _errorCode = switch (response.statusCode) {
          404 => SessionFailureCode.roomNotFound,
          429 => SessionFailureCode.rateLimited,
          _ => SessionFailureCode.requestFailed,
        };
        _error = 'session_request_failed_${response.statusCode}';
      }
    } catch (e, st) {
      _errorCode = SessionFailureCode.network;
      _error = 'session_network';
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
          _httpClient.post(
            Uri.parse('${ApiKeys.workerUrl}/api/realtime/client-secret'),
            headers: await _authHeaders(
                json: true,
                method: 'POST',
                path: '/api/realtime/client-secret',
                body: jsonEncode({'targetLanguage': targetLanguage})),
            body: jsonEncode({'targetLanguage': targetLanguage}),
          ),
          _requestTimeout,
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
