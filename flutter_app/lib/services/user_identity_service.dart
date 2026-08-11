import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/user_identity.dart';

class UserIdentityService extends ChangeNotifier {
  static const _legacyStorageKey = 'snail_user_identity';
  static const _secureStorageKey = 'snail_user_identity_v2';
  static const _secureStorage = FlutterSecureStorage();
  UserIdentity? _identity;
  UserIdentity? get identity => _identity;
  String get username => _identity?.username ?? 'Snail User';
  String get shortId =>
      _identity == null ? '—' : _identity!.userId.substring(0, 8);
  String? get qrPayload => _identity?.qrPayload;
  String? get publicKey => _identity?.publicKey;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = await _secureStorage.read(key: _secureStorageKey);
    if (raw != null) {
      _identity =
          UserIdentity.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } else {
      // One-time migration retains the user's existing contact identity while
      // moving it into Android Keystore-backed encrypted storage.
      final legacy = prefs.getString(_legacyStorageKey);
      _identity = legacy == null
          ? UserIdentity(userId: const Uuid().v4(), username: 'Snail User')
          : UserIdentity.fromJson(jsonDecode(legacy) as Map<String, dynamic>);
      await _persist();
      await prefs.remove(_legacyStorageKey);
    }
    final publicKey = await _loadDevicePublicKey();
    if (publicKey != null && publicKey.isNotEmpty && _identity!.publicKey != publicKey) {
      _identity = UserIdentity(
          userId: _identity!.userId,
          username: _identity!.username,
          publicKey: publicKey);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> setUsername(String username) async {
    final value = username.trim();
    if (value.isEmpty || _identity == null) return;
    _identity = UserIdentity(
        userId: _identity!.userId,
        username: value,
        publicKey: _identity!.publicKey);
    await _persist();
    notifyListeners();
  }

  Future<String?> _loadDevicePublicKey() async {
    try {
      return await const MethodChannel('com.snail.audio/method')
          .invokeMethod<String>('getDevicePublicKey');
    } catch (_) {
      // Non-Android builds retain the UUID identity until their native
      // keystore implementation is added.
      return null;
    }
  }

  Future<void> _persist() async {
    await _secureStorage.write(
      key: _secureStorageKey,
      value: jsonEncode(_identity!.toJson()),
    );
  }

  Future<String?> signDevicePayload(String payload) async {
    try {
      return await const MethodChannel('com.snail.audio/method')
          .invokeMethod<String>('signDevicePayload', {'payload': payload});
    } catch (_) {
      return null;
    }
  }
}
