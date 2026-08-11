import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import '../models/provider_config.dart';
import '../services/provider_config_service.dart';

class ProviderSettingsScreen extends StatefulWidget {
  const ProviderSettingsScreen({super.key});
  @override
  State<ProviderSettingsScreen> createState() => _ProviderSettingsScreenState();
}

class _ProviderSettingsScreenState extends State<ProviderSettingsScreen> {
  late TranslationProvider _provider;
  late TextEditingController _endpoint;
  late TextEditingController _model;
  late TextEditingController _chatModel;
  late TextEditingController _key;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    final config = context.read<ProviderConfigService>().config;
    _provider = config.provider;
    _endpoint = TextEditingController(text: config.endpoint);
    _model = TextEditingController(text: config.model);
    _chatModel = TextEditingController(text: config.chatModel);
    _key = TextEditingController(text: config.apiKey);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('BYOK-Provider')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<TranslationProvider>(
            value: _provider,
            decoration:
                const InputDecoration(labelText: 'Session-Owner-Provider'),
            items: const [
              DropdownMenuItem(
                  value: TranslationProvider.ollama, child: Text('Ollama')),
              DropdownMenuItem(
                  value: TranslationProvider.openAi,
                  child: Text('OpenAI Realtime-Übersetzung')),
              DropdownMenuItem(
                  value: TranslationProvider.geminiLive,
                  child: Text('Gemini Live (Audio)')),
            ],
            onChanged: (value) => _changeProvider(value ?? _provider),
          ),
          if (_provider != TranslationProvider.geminiLive)
            TextField(
                controller: _endpoint,
                decoration: const InputDecoration(labelText: 'Endpoint')),
          _modelField(),
          if (_provider == TranslationProvider.openAi) _chatModelField(),
          if (_provider != TranslationProvider.ollama)
            TextField(
                controller: _key,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Provider-Key')),
          const SizedBox(height: 24),
          FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Speichern')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: const Icon(Icons.network_check),
              label:
                  Text(_testing ? 'Teste Verbindung …' : 'Verbindung testen')),
          if (_testResult != null)
            Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_testResult!,
                    style: TextStyle(
                        color: _testResult!.startsWith('OK')
                            ? Colors.green
                            : Colors.red))),
          const SizedBox(height: 12),
          const Text(
              'Der Key gehört dem Session-Owner. Der eingeladene Teilnehmer benötigt keinen eigenen Provider-Key.'),
        ]),
      );

  void _changeProvider(TranslationProvider provider) {
    setState(() {
      _provider = provider;
      _endpoint.text = switch (provider) {
        TranslationProvider.ollama => 'http://127.0.0.1:11434',
        TranslationProvider.openAi => 'https://api.openai.com/v1',
        TranslationProvider.geminiLive =>
          'https://generativelanguage.googleapis.com',
      };
      _model.text = switch (provider) {
        TranslationProvider.ollama => 'llama3.2:3b',
        TranslationProvider.openAi => 'gpt-realtime-translate',
        TranslationProvider.geminiLive => 'gemini-3.5-live-translate-preview',
      };
      if (provider == TranslationProvider.openAi) {
        _chatModel.text = 'gpt-5.6-luna';
      }
      _testResult = null;
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      late http.Response response;
      final base = _endpoint.text.trim().replaceFirst(RegExp(r'/$'), '');
      if (_provider == TranslationProvider.ollama) {
        response = await http
            .get(Uri.parse('$base/api/tags'))
            .timeout(const Duration(seconds: 8));
      } else if (_provider == TranslationProvider.openAi) {
        response = await http.get(Uri.parse('$base/models'), headers: {
          'Authorization': 'Bearer ${_key.text.trim()}'
        }).timeout(const Duration(seconds: 8));
      } else {
        response = await http
            .get(Uri.parse(
                '$base/v1beta/models?key=${Uri.encodeQueryComponent(_key.text.trim())}'))
            .timeout(const Duration(seconds: 8));
      }
      if (!mounted) return;
      setState(() => _testResult =
          response.statusCode >= 200 && response.statusCode < 300
              ? 'OK – Provider erreichbar'
              : 'Fehler – HTTP ${response.statusCode}');
    } catch (error) {
      if (mounted) setState(() => _testResult = 'Fehler – $error');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _modelField() {
    final options = switch (_provider) {
      TranslationProvider.openAi => const ['gpt-realtime-translate'],
      TranslationProvider.geminiLive => const [
          'gemini-3.5-live-translate-preview',
          'gemini-3.1-flash-live-preview'
        ],
      TranslationProvider.ollama => const <String>[],
    };
    if (options.isEmpty) {
      return TextField(
          controller: _model,
          decoration: const InputDecoration(
              labelText: 'Ollama-Modell', hintText: 'z. B. llama3.2:3b'));
    }
    if (!options.contains(_model.text)) _model.text = options.first;
    return DropdownButtonFormField<String>(
      value: _model.text,
      decoration: const InputDecoration(labelText: 'Modell'),
      items: options
          .map((model) => DropdownMenuItem(value: model, child: Text(model)))
          .toList(),
      onChanged: (model) {
        if (model != null) setState(() => _model.text = model);
      },
    );
  }

  Widget _chatModelField() => DropdownButtonFormField<String>(
        value: _chatModel.text,
        decoration:
            const InputDecoration(labelText: 'Messenger-Übersetzungsmodell'),
        items: const [
          'gpt-5.6-luna',
          'gpt-5.6-terra',
          'gpt-5.6-sol',
          'gpt-5-mini',
          'gpt-5-nano',
          'gpt-4.1-mini',
          'gpt-4o-mini'
        ]
            .map((model) => DropdownMenuItem(value: model, child: Text(model)))
            .toList(),
        onChanged: (model) {
          if (model != null) setState(() => _chatModel.text = model);
        },
      );

  Future<void> _save() async {
    final endpoint = _provider == TranslationProvider.geminiLive
        ? 'https://generativelanguage.googleapis.com'
        : _endpoint.text.trim();
    await context.read<ProviderConfigService>().save(ProviderConfig(
        provider: _provider,
        endpoint: endpoint,
        model: _model.text.trim(),
        chatModel: _chatModel.text.trim(),
        apiKey: _key.text));
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _model.dispose();
    _chatModel.dispose();
    _key.dispose();
    super.dispose();
  }
}
