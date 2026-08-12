enum TranslationProvider { ollama, openAi, geminiLive, fishAudio }

extension TranslationProviderLabel on TranslationProvider {
  String get displayName => switch (this) {
        TranslationProvider.ollama => 'Ollama',
        TranslationProvider.openAi => 'OpenAI Realtime',
        TranslationProvider.geminiLive => 'Gemini Live',
        TranslationProvider.fishAudio => 'Fish Audio',
      };
}

class ProviderConfig {
  final TranslationProvider provider;
  final String endpoint;
  final String model;
  final String chatModel;
  final String apiKey;
  final String voiceId;
  final String latencyMode;
  final double temperature;
  final double topP;
  final double speed;
  final String translationEndpoint;
  final String translationModel;

  const ProviderConfig(
      {required this.provider,
      required this.endpoint,
      required this.model,
      this.chatModel = 'gpt-5.6-luna',
      this.apiKey = '',
      this.voiceId = '802e3bc2b27e49c2995d23ef70e6ac89',
      this.latencyMode = 'balanced',
      this.temperature = 0.7,
      this.topP = 0.7,
      this.speed = 1.0,
      this.translationEndpoint = 'http://127.0.0.1:11434',
      this.translationModel = 'llama3.2:3b'});

  bool get requiresApiKey => provider != TranslationProvider.ollama;

  Map<String, dynamic> toJson() => {
        'provider': provider.name,
        'endpoint': endpoint,
        'model': model,
        'chatModel': chatModel,
        'apiKey': apiKey,
        'voiceId': voiceId,
        'latencyMode': latencyMode,
        'temperature': temperature,
        'topP': topP,
        'speed': speed,
        'translationEndpoint': translationEndpoint,
        'translationModel': translationModel
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    final name = json['provider'] as String? ?? 'ollama';
    final provider = TranslationProvider.values.firstWhere(
        (v) => v.name == name,
        orElse: () => TranslationProvider.ollama);
    final defaultEndpoint = switch (provider) {
      TranslationProvider.ollama => 'http://127.0.0.1:11434',
      TranslationProvider.fishAudio => 'wss://api.fish.audio/v1/tts/live',
      _ => 'https://api.openai.com/v1',
    };
    final defaultModel = switch (provider) {
      TranslationProvider.geminiLive => 'gemini-3.5-live-translate-preview',
      TranslationProvider.ollama => 'llama3.2:3b',
      TranslationProvider.fishAudio => 's2-pro',
      TranslationProvider.openAi => 'gpt-5-mini',
    };
    return ProviderConfig(
        provider: provider,
        endpoint: json['endpoint'] as String? ?? defaultEndpoint,
        model: json['model'] as String? ?? defaultModel,
        chatModel: json['chatModel'] as String? ?? 'gpt-5.6-luna',
        apiKey: json['apiKey'] as String? ?? '',
        voiceId:
            json['voiceId'] as String? ?? '802e3bc2b27e49c2995d23ef70e6ac89',
        latencyMode: json['latencyMode'] as String? ?? 'balanced',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        topP: (json['topP'] as num?)?.toDouble() ?? 0.7,
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        translationEndpoint:
            json['translationEndpoint'] as String? ?? 'http://127.0.0.1:11434',
        translationModel: json['translationModel'] as String? ?? 'llama3.2:3b');
  }
}
