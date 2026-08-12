import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/provider_config.dart';
import '../services/provider_config_service.dart';
import '../services/fish_audio_realtime_service.dart';
import '../services/snail_audio.dart';

class ProviderSettingsScreen extends StatefulWidget {
  const ProviderSettingsScreen({super.key});
  @override
  State<ProviderSettingsScreen> createState() => _ProviderSettingsScreenState();
}

class _ProviderSettingsScreenState extends State<ProviderSettingsScreen> {
  static const _curatedFishVoices = <_FishVoice>[
    _FishVoice(
        id: '2d4039641d67419fa132ca59fa2f61ad',
        title: 'Cid',
        languages: [],
        tags: ['Kuratierte Stimme']),
    _FishVoice(
        id: '42039da0dcbd49bc8846fc1c12def1f4',
        title: 'Mr. Fox',
        languages: [],
        tags: ['Kuratierte Stimme']),
  ];
  late TranslationProvider _provider;
  late TextEditingController _endpoint;
  late TextEditingController _model;
  late TextEditingController _chatModel;
  late TextEditingController _key;
  late TextEditingController _translationEndpoint;
  late TextEditingController _translationModel;
  bool _testing = false;
  String? _testResult;
  Map<String, String>? _diagnostics;
  String _fishVoiceId = '802e3bc2b27e49c2995d23ef70e6ac89';
  final _fishSearch = TextEditingController();
  late TextEditingController _fishManualVoice;
  List<_FishVoice> _fishVoices = _curatedFishVoices;
  String _fishLanguage = 'Alle';
  String _fishTag = 'Alle';
  final Set<String> _fishFavorites = <String>{};
  bool _loadingFishVoices = false;
  final _previewFish = FishAudioRealtimeService();
  final _previewAudio = SnailAudio();
  Timer? _previewTimer;
  bool _previewing = false;
  double _fishTemperature = 0.7;
  double _fishTopP = 0.7;
  double _fishSpeed = 1.0;
  String _fishLatency = 'balanced';

  @override
  void initState() {
    super.initState();
    final config = context.read<ProviderConfigService>().config;
    _provider = config.provider;
    _endpoint = TextEditingController(text: config.endpoint);
    _model = TextEditingController(text: config.model);
    _chatModel = TextEditingController(text: config.chatModel);
    _key = TextEditingController(text: config.apiKey);
    _translationEndpoint =
        TextEditingController(text: config.translationEndpoint);
    _translationModel = TextEditingController(text: config.translationModel);
    _fishVoiceId = config.voiceId;
    _fishTemperature = config.temperature;
    _fishTopP = config.topP;
    _fishSpeed = config.speed;
    _fishLatency = const ['balanced', 'normal'].contains(config.latencyMode)
        ? config.latencyMode
        : 'balanced';
    _fishManualVoice = TextEditingController(text: _fishVoiceId);
    _loadFishFavorites();
    if (_provider == TranslationProvider.fishAudio) _loadFishVoices();
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
              DropdownMenuItem(
                  value: TranslationProvider.fishAudio,
                  child: Text('Fish Audio Realtime (günstig)')),
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
          if (_provider == TranslationProvider.fishAudio) _fishVoiceField(),
          if (_provider == TranslationProvider.fishAudio) ...[
            _fishParameterSliders(),
            DropdownButtonFormField<String>(
                value: _fishLatency,
                decoration: const InputDecoration(
                    labelText: 'Fish-Latenzmodus'),
                items: const [
                  DropdownMenuItem(value: 'balanced', child: Text('Balanced – empfohlen')),
                  DropdownMenuItem(value: 'normal', child: Text('Normal – höchste Qualität')),
                ],
                onChanged: (value) =>
                    setState(() => _fishLatency = value ?? 'balanced')),
            TextField(
                controller: _translationEndpoint,
                decoration: const InputDecoration(
                    labelText: 'Günstige MT-Engine Endpoint',
                    hintText: 'Ollama im WLAN, z. B. http://192.168.1.10:11434')),
            TextField(
                controller: _translationModel,
                decoration: const InputDecoration(
                    labelText: 'Lokales Übersetzungsmodell',
                    hintText: 'z. B. llama3.2:3b')),
          ],
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
        TranslationProvider.fishAudio => 'wss://api.fish.audio/v1/tts/live',
      };
      _model.text = switch (provider) {
        TranslationProvider.ollama => 'llama3.2:3b',
        TranslationProvider.openAi => 'gpt-realtime-translate',
        TranslationProvider.geminiLive => 'gemini-3.5-live-translate-preview',
        TranslationProvider.fishAudio => 's2-pro',
      };
      if (provider == TranslationProvider.openAi) {
        _chatModel.text = 'gpt-5.6-luna';
      }
      _testResult = null;
      _diagnostics = null;
    });
    if (provider == TranslationProvider.fishAudio) _loadFishVoices();
  }

  Future<void> _loadFishVoices() async {
    if (_loadingFishVoices || _key.text.trim().isEmpty) return;
    setState(() => _loadingFishVoices = true);
    final prefs = await SharedPreferences.getInstance();
    try {
      final response = await http.get(
        Uri.parse('https://api.fish.audio/model?page_size=30'),
        headers: {'Authorization': 'Bearer ${_key.text.trim()}'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _restoreCachedFishVoices(prefs);
        return;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final items = (body['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      await prefs.setString('fish_voice_catalog', jsonEncode(items));
      if (!mounted) return;
      _setFishVoices(items);
    } catch (_) {
      _restoreCachedFishVoices(prefs);
    } finally {
      if (mounted) setState(() => _loadingFishVoices = false);
    }
  }

  void _restoreCachedFishVoices(SharedPreferences prefs) {
    final raw = prefs.getString('fish_voice_catalog');
    if (raw == null) return;
    try {
      final items = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (mounted) _setFishVoices(items);
    } catch (_) {
      // Corrupt cache is disposable; manual Voice-ID still works.
    }
  }

  void _setFishVoices(List<Map<String, dynamic>> items) {
    if (!mounted) return;
    setState(() {
      final loaded = items
          .map((item) => _FishVoice(
              id: item['_id']?.toString() ?? '',
              title: item['title']?.toString() ?? '',
              languages: (item['languages'] as List<dynamic>? ?? const [])
                  .map((v) => v.toString())
                  .toList(),
              tags: (item['tags'] as List<dynamic>? ?? const [])
                  .map((v) => v.toString())
                  .toList()))
          .where((voice) => voice.id.isNotEmpty)
          .toList();
      final ids = loaded.map((voice) => voice.id).toSet();
      _fishVoices = [
        ..._curatedFishVoices.where((voice) => !ids.contains(voice.id)),
        ...loaded,
      ];
    });
  }

  Future<void> _loadFishFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _fishFavorites.addAll(
        prefs.getStringList('fish_voice_favorites') ?? const <String>[]));
  }

  Future<void> _toggleFishFavorite(String id) async {
    setState(() {
      if (!_fishFavorites.add(id)) _fishFavorites.remove(id);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'fish_voice_favorites', _fishFavorites.toList(growable: false));
  }

  Future<void> _previewFishVoice(_FishVoice voice) async {
    if (_previewing || _key.text.trim().isEmpty) return;
    setState(() => _previewing = true);
    try {
      await _previewFish.connect(
          apiKey: _key.text.trim(),
          voiceId: voice.id,
          latency: _fishLatency,
          model: _model.text.trim().isEmpty ? 's2-pro' : _model.text.trim(),
          temperature: _fishTemperature,
          topP: _fishTopP,
          speed: _fishSpeed);
      _previewFish.sendText('Hallo, das ist eine kurze Fish-Audio-Stimmprobe.');
      _previewFish.flush();
      _previewTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        for (final chunk in _previewFish.takeAudioChunks()) {
          _previewAudio.playPcm16(chunk, sampleRate: 24000);
        }
      });
      await Future<void>.delayed(const Duration(seconds: 4));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fish-Voice-Vorschau fehlgeschlagen: $error')));
      }
    } finally {
      _previewTimer?.cancel();
      _previewTimer = null;
      await _previewFish.disconnect();
      if (mounted) setState(() => _previewing = false);
    }
  }

  List<_FishVoice> get _filteredFishVoices {
    final query = _fishSearch.text.trim().toLowerCase();
    return _fishVoices.where((voice) {
      final matchesQuery = query.isEmpty ||
          voice.title.toLowerCase().contains(query) ||
          voice.id.toLowerCase().contains(query);
      final matchesLanguage = _fishLanguage == 'Alle' ||
          voice.languages.any((value) =>
              value.toLowerCase() == _fishLanguage.toLowerCase());
      final matchesTag = _fishTag == 'Alle' || voice.tags.contains(_fishTag);
      return matchesQuery && matchesLanguage && matchesTag;
    }).toList();
  }

  Widget _fishVoiceBrowser() {
    final voices = _filteredFishVoices;
    final languages = <String>{
      'Alle',
      ..._fishVoices.expand((voice) => voice.languages)
    }.toList()
      ..sort();
    final tags = <String>{'Alle', ..._fishVoices.expand((voice) => voice.tags)}
        .toList()
      ..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _fishSearch,
        decoration: const InputDecoration(
            labelText: 'Stimme suchen', prefixIcon: Icon(Icons.search)),
        onChanged: (_) => setState(() {}),
      ),
      Row(children: [
        Expanded(
            child: DropdownButtonFormField<String>(
                value: languages.contains(_fishLanguage) ? _fishLanguage : 'Alle',
                decoration: const InputDecoration(labelText: 'Sprache'),
                items: languages
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => _fishLanguage = v ?? 'Alle'))),
        const SizedBox(width: 8),
        Expanded(
            child: DropdownButtonFormField<String>(
                value: tags.contains(_fishTag) ? _fishTag : 'Alle',
                decoration: const InputDecoration(labelText: 'Kategorie'),
                items: tags
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => _fishTag = v ?? 'Alle'))),
      ]),
      const SizedBox(height: 8),
      if (_fishVoices.isNotEmpty)
        Text('${voices.length} Fish-Voices geladen',
            style: Theme.of(context).textTheme.bodySmall),
      ...voices.take(30).map((voice) => ListTile(
            dense: true,
            leading: Icon(voice.id == _fishVoiceId
                ? Icons.check_circle
                : Icons.record_voice_over),
            title: Text(voice.title.isEmpty ? voice.id : voice.title),
            subtitle: Text(voice.languages.isEmpty
                ? voice.id
                : '${voice.languages.join(', ')} · ${voice.id}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: 'Vorschau',
                  icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                  onPressed: _previewing ? null : () => _previewFishVoice(voice)),
              IconButton(
                  tooltip: 'Favorit',
                  icon: Icon(_fishFavorites.contains(voice.id)
                      ? Icons.star
                      : Icons.star_border),
                  onPressed: () => _toggleFishFavorite(voice.id)),
            ]),
            onTap: () => setState(() {
              _fishVoiceId = voice.id;
              _fishManualVoice.text = voice.id;
            }),
          )),
    ]);
  }

  Widget _fishParameterSliders() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fish-Audio-Qualität',
              style: Theme.of(context).textTheme.titleSmall),
          _fishSlider('Temperature', _fishTemperature, 0, 1,
              (value) => setState(() => _fishTemperature = value)),
          _fishSlider('Top-p', _fishTopP, 0, 1,
              (value) => setState(() => _fishTopP = value)),
          _fishSlider('Sprechgeschwindigkeit', _fishSpeed, 0.5, 2,
              (value) => setState(() => _fishSpeed = value)),
        ],
      );

  Widget _fishSlider(String label, double value, double min, double max,
          ValueChanged<double> onChanged) => Row(children: [
        SizedBox(width: 150, child: Text('$label: ${value.toStringAsFixed(2)}')),
        Expanded(
            child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: ((max - min) * 20).round(),
                onChanged: onChanged)),
      ]);

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
      } else if (_provider == TranslationProvider.geminiLive) {
        response = await http
            .get(Uri.parse(
                '$base/v1beta/models?key=${Uri.encodeQueryComponent(_key.text.trim())}'))
            .timeout(const Duration(seconds: 8));
      } else {
        response = await http.get(Uri.parse('https://api.fish.audio/model'),
            headers: {'Authorization': 'Bearer ${_key.text.trim()}'})
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
      TranslationProvider.fishAudio => const [
          's2.1-pro-free',
          's2-pro',
          's2.1-pro',
          's1',
        ],
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
          .map((model) => DropdownMenuItem(
              value: model,
              child: Text(model == 's2.1-pro-free'
                  ? 's2.1-pro-free (kostenlos)'
                  : model)))
          .toList(),
      onChanged: (model) {
        if (model != null) setState(() => _model.text = model);
      },
    );
  }

  Widget _fishVoiceField() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fish Audio Stimme',
              style: Theme.of(context).textTheme.titleMedium),
          Text('reference_id: $_fishVoiceId',
              style: Theme.of(context).textTheme.bodySmall),
          if (_loadingFishVoices)
            const LinearProgressIndicator(minHeight: 2)
          else
            _fishVoiceBrowser(),
          TextField(
              decoration: const InputDecoration(labelText: 'Manuelle Voice-ID'),
              controller: _fishManualVoice,
              onChanged: (value) => _fishVoiceId = value.trim()),
        ],
      );

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
        apiKey: _key.text,
        voiceId: _fishVoiceId,
        latencyMode: _fishLatency,
        temperature: _fishTemperature,
        topP: _fishTopP,
        speed: _fishSpeed,
        translationEndpoint: _translationEndpoint.text.trim(),
        translationModel: _translationModel.text.trim()));
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _model.dispose();
    _chatModel.dispose();
    _key.dispose();
    _translationEndpoint.dispose();
    _translationModel.dispose();
    _fishSearch.dispose();
    _fishManualVoice.dispose();
    _previewTimer?.cancel();
    _previewFish.dispose();
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
    TranslationProvider.fishAudio: _ProviderDescription(
      title: 'Fish Audio Realtime',
      subtitle: 'Realtime-TTS · günstig · eigener Voice-Key',
      body: 'Fish Audio streamt die übersetzten Textstücke per WebSocket in '
          'natürliche Audio-Chunks. Die Übersetzung selbst bleibt eine separate '
          'STT/MT-Stufe. Wähle eine Voice-ID und den balanced-Latenzmodus.',
      icon: Icons.graphic_eq_rounded,
      color: Color(0xFF2E8B57),
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

class _FishVoice {
  const _FishVoice({
    required this.id,
    required this.title,
    required this.languages,
    required this.tags,
  });

  final String id;
  final String title;
  final List<String> languages;
  final List<String> tags;
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
