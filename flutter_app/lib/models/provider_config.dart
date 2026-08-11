enum TranslationProvider { ollama, openAi, geminiLive }

class ProviderConfig {
  final TranslationProvider provider;
  final String endpoint;
  final String model;
  final String chatModel;
  final String apiKey;

  const ProviderConfig(
      {required this.provider,
      required this.endpoint,
      required this.model,
      this.chatModel = 'gpt-5.6-luna',
      this.apiKey = ''});

  bool get requiresApiKey => provider != TranslationProvider.ollama;

  Map<String, dynamic> toJson() => {
        'provider': provider.name,
        'endpoint': endpoint,
        'model': model,
        'chatModel': chatModel,
        'apiKey': apiKey
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    final name = json['provider'] as String? ?? 'ollama';
    final provider = TranslationProvider.values.firstWhere(
        (v) => v.name == name,
        orElse: () => TranslationProvider.ollama);
    final defaultEndpoint = provider == TranslationProvider.ollama
        ? 'http://127.0.0.1:11434'
        : 'https://api.openai.com/v1';
    final defaultModel = provider == TranslationProvider.geminiLive
        ? 'gemini-3.5-live-translate-preview'
        : (provider == TranslationProvider.ollama
            ? 'llama3.2:3b'
            : 'gpt-5-mini');
    return ProviderConfig(
        provider: provider,
        endpoint: json['endpoint'] as String? ?? defaultEndpoint,
        model: json['model'] as String? ?? defaultModel,
        chatModel: json['chatModel'] as String? ?? 'gpt-5.6-luna',
        apiKey: json['apiKey'] as String? ?? '');
  }
}
