import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/provider_config.dart';

class ProviderConfigService extends ChangeNotifier {
  static const _storageKey = 'snail_provider_config';
  static const _secureStorage = FlutterSecureStorage();
  ProviderConfig _config = const ProviderConfig(
    provider: TranslationProvider.fishAudio,
    endpoint: 'wss://api.fish.audio/v1/tts/live',
    model: 's2-pro',
  );

  ProviderConfig get config => _config;

  Future<void> init() async {
    final raw = await _secureStorage.read(key: _storageKey);
    if (raw != null) {
      _config =
          ProviderConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    notifyListeners();
  }

  Future<void> save(ProviderConfig config) async {
    _config = config;
    await _secureStorage.write(
        key: _storageKey, value: jsonEncode(config.toJson()));
    notifyListeners();
  }
}
