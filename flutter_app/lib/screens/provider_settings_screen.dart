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
  Map<String, String>? _diagnostics;

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
          if (_diagnostics != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Diagnosebericht',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 8),
                    ..._diagnostics!.entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 110,
                                child: Text('${e.key}:',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6))),
                              ),
                              Expanded(
                                child: Text(e.value,
                                    style: const TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _ProviderInfo(provider: _provider),
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
      _diagnostics = null;
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _diagnostics = null;
    });
    final diagnostics = <String, String>{};
    final stopwatch = Stopwatch()..start();
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
      stopwatch.stop();
      final latencyMs = stopwatch.elapsedMilliseconds;
      diagnostics['Latenz'] = '$latencyMs ms';
      diagnostics['HTTP-Status'] = '${response.statusCode}';
      diagnostics['Endpoint'] = base;
      diagnostics['Zeitpunkt'] = DateTime.now().toIso8601String();

      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok) {
        diagnostics['Key-Status'] = 'gültig';
        // Check if the selected model is in the response
        final body = response.body.toLowerCase();
        final model = _model.text.trim().toLowerCase();
        diagnostics['Modell gefunden'] =
            body.contains(model) ? 'ja' : 'nein (Modellname prüfen)';
      } else {
        diagnostics['Key-Status'] = response.statusCode == 401 || response.statusCode == 403
            ? 'ungültig (Key prüfen)'
            : 'Fehler (HTTP ${response.statusCode})';
      }

      if (!mounted) return;
      setState(() {
        _testResult = ok ? 'OK – Provider erreichbar' : 'Fehler – HTTP ${response.statusCode}';
        _diagnostics = diagnostics;
      });
    } catch (error) {
      stopwatch.stop();
      diagnostics['Fehler'] = '$error';
      diagnostics['Latenz'] = '${stopwatch.elapsedMilliseconds} ms (Timeout/Fehler)';
      diagnostics['Zeitpunkt'] = DateTime.now().toIso8601String();
      if (mounted) {
        setState(() {
          _testResult = 'Fehler – $error';
          _diagnostics = diagnostics;
        });
      }
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

class _ProviderInfo extends StatelessWidget {
  const _ProviderInfo({required this.provider});

  final TranslationProvider provider;

  static const _descriptions = <TranslationProvider, _ProviderDescription>{
    TranslationProvider.openAi: _ProviderDescription(
      title: 'OpenAI Realtime-Übersetzung',
      subtitle: 'Cloud · niedrigste Latenz · API-Key nötig',
      body: 'OpenAI übersetzt gesprochene Sprache direkt in Echtzeit — '
          'ohne Umweg über Text. Das ist der schnellste Weg und die '
          'empfohlene Wahl für Live-Gespräche. '
          'Du brauchst einen OpenAI-API-Key (sk-...). '
          'Kosten: ca. \$0,034 pro Minute Audio.',
      icon: Icons.bolt_rounded,
      color: Color(0xFF10A37F),
    ),
    TranslationProvider.geminiLive: _ProviderDescription(
      title: 'Gemini Live',
      subtitle: 'Cloud · gute Latenz · API-Key nötig',
      body: 'Google Gemini übersetzt Audio-Streams live. '
          'Gute Alternative zu OpenAI mit ähnlicher Latenz. '
          'Du brauchst einen Gemini-API-Key von Google AI Studio. '
          'Kosten: kostenlos im Rahmen des Google AI Studio-Kontingents.',
      icon: Icons.auto_awesome_rounded,
      color: Color(0xFF4285F4),
    ),
    TranslationProvider.ollama: _ProviderDescription(
      title: 'Ollama (lokal)',
      subtitle: 'Lokal · kein API-Key · höhere Latenz',
      body: 'Ollama läuft auf deinem eigenen Rechner. '
          'Deine Daten verlassen dein Netzwerk nicht. '
          'Ideal, wenn du bereits einen Ollama-Server betreibst. '
          'Nicht empfohlen für Live-Gespräche — '
          'die Latenz ist spürbar höher als bei Cloud-Providern. '
          'Kein API-Key nötig.',
      icon: Icons.computer_rounded,
      color: Color(0xFF6F36A7),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final desc = _descriptions[provider];
    if (desc == null) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: desc.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(desc.icon, color: desc.color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      desc.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      desc.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            desc.body,
            style: TextStyle(
              fontSize: 13,
              color: colors.onSurface.withValues(alpha: 0.8),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderDescription {
  const _ProviderDescription({
    required this.title,
    required this.subtitle,
    required this.body,
    required this.icon,
    required this.color,
  });

  final String title;
  final String subtitle;
  final String body;
  final IconData icon;
  final Color color;
}
