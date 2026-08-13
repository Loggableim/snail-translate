import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../l10n/app_localizations.dart';
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
  bool _testOk = false;
  Map<String, String>? _diagnostics;
  String _fishVoiceId = '802e3bc2b27e49c2995d23ef70e6ac89';
  final _fishSearch = TextEditingController();
  late TextEditingController _fishManualVoice;
  List<_FishVoice> _fishVoices = _curatedFishVoices;
  // Empty string is the internal "no filter" sentinel, decoupled from its
  // displayed label so the label can be localized without breaking the
  // equality checks below.
  String _fishLanguage = '';
  String _fishTag = '';
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.providerSettingsTitle)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<TranslationProvider>(
          value: _provider,
          decoration: InputDecoration(
              labelText: l10n.providerSettingsSessionOwnerProvider),
          items: [
            DropdownMenuItem(
                value: TranslationProvider.ollama, child: const Text('Ollama')),
            DropdownMenuItem(
                value: TranslationProvider.openAi,
                child: Text(l10n.providerSettingsOpenAiRealtime)),
            DropdownMenuItem(
                value: TranslationProvider.geminiLive,
                child: Text(l10n.providerSettingsGeminiLive)),
            DropdownMenuItem(
                value: TranslationProvider.fishAudio,
                child: Text(l10n.providerSettingsFishAudioRealtime)),
          ],
          onChanged: (value) => _changeProvider(value ?? _provider),
        ),
        if (_provider != TranslationProvider.geminiLive)
          TextField(
              controller: _endpoint,
              decoration:
                  InputDecoration(labelText: l10n.providerSettingsEndpoint)),
        _modelField(),
        if (_provider == TranslationProvider.openAi) _chatModelField(),
        if (_provider != TranslationProvider.ollama)
          TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                  labelText: l10n.providerSettingsProviderKey)),
        if (_provider == TranslationProvider.fishAudio) _fishVoiceField(),
        if (_provider == TranslationProvider.fishAudio) ...[
          _fishParameterSliders(),
          DropdownButtonFormField<String>(
              value: _fishLatency,
              decoration: InputDecoration(
                  labelText: l10n.providerSettingsFishLatencyMode),
              items: [
                DropdownMenuItem(
                    value: 'balanced',
                    child: Text(l10n.providerSettingsLatencyBalanced)),
                DropdownMenuItem(
                    value: 'normal',
                    child: Text(l10n.providerSettingsLatencyNormal)),
              ],
              onChanged: (value) =>
                  setState(() => _fishLatency = value ?? 'balanced')),
          TextField(
              controller: _translationEndpoint,
              decoration: InputDecoration(
                  labelText: l10n.providerSettingsMtEndpoint,
                  hintText: l10n.providerSettingsMtEndpointHint)),
          TextField(
              controller: _translationModel,
              decoration: InputDecoration(
                  labelText: l10n.providerSettingsLocalTranslationModel,
                  hintText: l10n.providerSettingsLocalTranslationModelHint)),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: Text(l10n.commonSave)),
        const SizedBox(height: 10),
        OutlinedButton.icon(
            onPressed: _testing ? null : _testConnection,
            icon: const Icon(Icons.network_check),
            label: Text(_testing
                ? l10n.providerSettingsTestingConnection
                : l10n.providerSettingsTestConnection)),
        if (_testResult != null)
          Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_testResult!,
                  style: TextStyle(
                      color: _testOk ? Colors.green : Colors.red))),
        if (_diagnostics != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.providerSettingsDiagnosticsTitle,
                      style: const TextStyle(
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
        Text(l10n.providerSettingsKeyOwnerHint),
      ]),
    );
  }

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
    final l10n = AppLocalizations.of(context);
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
      _previewFish.sendText(l10n.providerSettingsVoicePreviewSample);
      _previewFish.flush();
      _previewTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        for (final chunk in _previewFish.takeAudioChunks()) {
          _previewAudio.playPcm16(chunk, sampleRate: 24000);
        }
      });
      await Future<void>.delayed(const Duration(seconds: 4));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                l10n.providerSettingsVoicePreviewFailed(error.toString()))));
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
      final matchesLanguage = _fishLanguage.isEmpty ||
          voice.languages.any((value) =>
              value.toLowerCase() == _fishLanguage.toLowerCase());
      final matchesTag = _fishTag.isEmpty || voice.tags.contains(_fishTag);
      return matchesQuery && matchesLanguage && matchesTag;
    }).toList();
  }

  Widget _fishVoiceBrowser() {
    final l10n = AppLocalizations.of(context);
    final voices = _filteredFishVoices;
    final languages = <String>{
      '',
      ..._fishVoices.expand((voice) => voice.languages)
    }.toList()
      ..sort();
    final tags = <String>{'', ..._fishVoices.expand((voice) => voice.tags)}
        .toList()
      ..sort();
    String labelFor(String value) =>
        value.isEmpty ? l10n.providerSettingsFilterAll : value;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _fishSearch,
        decoration: InputDecoration(
            labelText: l10n.providerSettingsSearchVoice,
            prefixIcon: const Icon(Icons.search)),
        onChanged: (_) => setState(() {}),
      ),
      Row(children: [
        Expanded(
            child: DropdownButtonFormField<String>(
                value: languages.contains(_fishLanguage) ? _fishLanguage : '',
                decoration:
                    InputDecoration(labelText: l10n.providerSettingsLanguage),
                items: languages
                    .map((v) =>
                        DropdownMenuItem(value: v, child: Text(labelFor(v))))
                    .toList(),
                onChanged: (v) => setState(() => _fishLanguage = v ?? ''))),
        const SizedBox(width: 8),
        Expanded(
            child: DropdownButtonFormField<String>(
                value: tags.contains(_fishTag) ? _fishTag : '',
                decoration:
                    InputDecoration(labelText: l10n.providerSettingsCategory),
                items: tags
                    .map((v) =>
                        DropdownMenuItem(value: v, child: Text(labelFor(v))))
                    .toList(),
                onChanged: (v) => setState(() => _fishTag = v ?? ''))),
      ]),
      const SizedBox(height: 8),
      if (_fishVoices.isNotEmpty)
        Text(l10n.providerSettingsVoicesLoaded(voices.length),
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
                  tooltip: l10n.providerSettingsPreview,
                  icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                  onPressed: _previewing ? null : () => _previewFishVoice(voice)),
              IconButton(
                  tooltip: l10n.providerSettingsFavorite,
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

  Widget _fishParameterSliders() {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.providerSettingsFishQuality,
            style: Theme.of(context).textTheme.titleSmall),
        _fishSlider('Temperature', _fishTemperature, 0, 1,
            (value) => setState(() => _fishTemperature = value)),
        _fishSlider('Top-p', _fishTopP, 0, 1,
            (value) => setState(() => _fishTopP = value)),
        _fishSlider(l10n.providerSettingsSpeakingRate, _fishSpeed, 0.5, 2,
            (value) => setState(() => _fishSpeed = value)),
      ],
    );
  }

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
    final l10n = AppLocalizations.of(context);
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
      diagnostics[l10n.providerSettingsDiagLatency] = '$latencyMs ms';
      diagnostics[l10n.providerSettingsDiagHttpStatus] =
          '${response.statusCode}';
      diagnostics[l10n.providerSettingsDiagEndpoint] = base;
      diagnostics[l10n.providerSettingsDiagTimestamp] =
          DateTime.now().toIso8601String();
      if (_provider == TranslationProvider.fishAudio) {
        final voiceId = _fishVoiceId.trim();
        diagnostics[l10n.providerSettingsDiagVoiceId] =
            voiceId.isEmpty ? l10n.providerSettingsDiagNotSet : voiceId;
        diagnostics[l10n.providerSettingsDiagVoiceInCatalog] =
            voiceId.isNotEmpty && response.body.contains(voiceId)
                ? l10n.providerSettingsDiagYes
                : l10n.providerSettingsDiagNoCheckVoiceId;
      }

      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok) {
        diagnostics[l10n.providerSettingsDiagKeyStatus] =
            l10n.providerSettingsDiagValid;
        // Check if the selected model is in the response
        final body = response.body.toLowerCase();
        final model = _model.text.trim().toLowerCase();
        diagnostics[l10n.providerSettingsDiagModelFound] = body.contains(model)
            ? l10n.providerSettingsDiagYes
            : l10n.providerSettingsDiagNoCheckModelName;
      } else {
        diagnostics[l10n.providerSettingsDiagKeyStatus] =
            response.statusCode == 401 || response.statusCode == 403
                ? l10n.providerSettingsDiagInvalidCheckKey
                : l10n.providerSettingsDiagErrorHttp(response.statusCode);
      }

      if (!mounted) return;
      setState(() {
        _testOk = ok;
        _testResult = ok
            ? l10n.providerSettingsResultOk
            : l10n.providerSettingsResultErrorHttp(response.statusCode);
        _diagnostics = diagnostics;
      });
    } catch (error) {
      stopwatch.stop();
      diagnostics[l10n.providerSettingsDiagError] = '$error';
      diagnostics[l10n.providerSettingsDiagLatency] =
          l10n.providerSettingsDiagLatencyTimeout(
              stopwatch.elapsedMilliseconds);
      diagnostics[l10n.providerSettingsDiagTimestamp] =
          DateTime.now().toIso8601String();
      if (mounted) {
        setState(() {
          _testOk = false;
          _testResult = l10n.providerSettingsResultError(error.toString());
          _diagnostics = diagnostics;
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _modelField() {
    final l10n = AppLocalizations.of(context);
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
          decoration: InputDecoration(
              labelText: l10n.providerSettingsOllamaModel,
              hintText: l10n.providerSettingsOllamaModelHint));
    }
    if (!options.contains(_model.text)) _model.text = options.first;
    return DropdownButtonFormField<String>(
      value: _model.text,
      decoration: InputDecoration(labelText: l10n.providerSettingsModel),
      items: options
          .map((model) => DropdownMenuItem(
              value: model,
              child: Text(model == 's2.1-pro-free'
                  ? l10n.providerSettingsModelFreeSuffix(model)
                  : model)))
          .toList(),
      onChanged: (model) {
        if (model != null) setState(() => _model.text = model);
      },
    );
  }

  Widget _fishVoiceField() {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.providerSettingsFishAudioVoice,
            style: Theme.of(context).textTheme.titleMedium),
        Text('reference_id: $_fishVoiceId',
            style: Theme.of(context).textTheme.bodySmall),
        if (_loadingFishVoices)
          const LinearProgressIndicator(minHeight: 2)
        else
          _fishVoiceBrowser(),
        TextField(
            decoration: InputDecoration(
                labelText: l10n.providerSettingsManualVoiceId),
            controller: _fishManualVoice,
            onChanged: (value) => _fishVoiceId = value.trim()),
      ],
    );
  }

  Widget _chatModelField() {
    final l10n = AppLocalizations.of(context);
    return DropdownButtonFormField<String>(
      value: _chatModel.text,
      decoration: InputDecoration(
          labelText: l10n.providerSettingsMessengerModel),
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
  }

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

  Map<TranslationProvider, _ProviderDescription> _descriptions(
          AppLocalizations l10n) =>
      <TranslationProvider, _ProviderDescription>{
        TranslationProvider.openAi: _ProviderDescription(
          title: l10n.providerSettingsOpenAiRealtime,
          subtitle: l10n.providerInfoOpenAiSubtitle,
          body: l10n.providerInfoOpenAiBody,
          icon: Icons.bolt_rounded,
          color: const Color(0xFF10A37F),
        ),
        TranslationProvider.geminiLive: _ProviderDescription(
          title: l10n.providerInfoGeminiTitle,
          subtitle: l10n.providerInfoGeminiSubtitle,
          body: l10n.providerInfoGeminiBody,
          icon: Icons.auto_awesome_rounded,
          color: const Color(0xFF4285F4),
        ),
        TranslationProvider.ollama: _ProviderDescription(
          title: l10n.providerInfoOllamaTitle,
          subtitle: l10n.providerInfoOllamaSubtitle,
          body: l10n.providerInfoOllamaBody,
          icon: Icons.computer_rounded,
          color: const Color(0xFF6F36A7),
        ),
        TranslationProvider.fishAudio: _ProviderDescription(
          title: l10n.providerInfoFishTitle,
          subtitle: l10n.providerInfoFishSubtitle,
          body: l10n.providerInfoFishBody,
          icon: Icons.graphic_eq_rounded,
          color: const Color(0xFF2E8B57),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final desc = _descriptions(l10n)[provider];
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
