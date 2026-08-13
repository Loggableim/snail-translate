import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../l10n/app_localizations.dart';
import '../services/snail_audio.dart';
import '../services/openai_realtime_service.dart';
import '../services/gemini_live_service.dart';
import '../services/fish_audio_realtime_service.dart';
import '../services/fish_audio_asr_service.dart';
import '../services/translation_service.dart';
import '../services/provider_config_service.dart';
import '../services/session_service.dart';
import '../services/audio_policy.dart';
import '../models/provider_config.dart';

class StandaloneScreen extends StatefulWidget {
  const StandaloneScreen({super.key});
  @override
  State<StandaloneScreen> createState() => _StandaloneScreenState();
}

class _StandaloneScreenState extends State<StandaloneScreen> {
  static const _languageCodes = <String, String>{
    'Deutsch': 'de',
    'English': 'en',
    'Français': 'fr',
    'Español': 'es',
    'Italiano': 'it',
    'Türkçe': 'tr',
    'Українська': 'uk',
  };
  final _audio = SnailAudio();
  final _phoneOpenAi = OpenAiRealtimeService();
  final _headsetOpenAi = OpenAiRealtimeService();
  final _phoneGemini = GeminiLiveService();
  final _headsetGemini = GeminiLiveService();
  final _phoneFish = FishAudioRealtimeService();
  final _headsetFish = FishAudioRealtimeService();
  final _fishAsr = FishAudioAsrService();
  final _translator = TranslationService();
  final Map<String, BytesBuilder> _fishBuffers = <String, BytesBuilder>{};
  final Map<String, bool> _fishBusy = <String, bool>{};
  Timer? _fishProcessTimer;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _playbackTimer;
  Timer? _playbackFlushTimer;
  Timer? _uiRefreshTimer;
  final List<_PlaybackChunk> _playbackQueue = <_PlaybackChunk>[];
  bool _playbackDraining = false;
  bool _fishPlaybackPrebuffer = false;
  static const _maxPlaybackQueue = 24;
  bool _running = false;
  String _phoneLanguage = 'Deutsch';
  String _headsetLanguage = 'English';
  // Raw state rather than pre-translated text, so the locale can change
  // (or the widget can simply be localized) without stale strings sticking
  // around in State fields declared before a BuildContext exists.
  String? _lastSourceKey;
  _StandaloneStatus _status = const _StandaloneStatus.ready();
  int _sourceFrames = 0;
  DateTime? _lastFrameAt;
  bool _hasHeadset = false;
  Map<String, dynamic> _audioDiagnostics = const <String, dynamic>{};

  Future<void> _toggle() async {
    if (_running) {
      await _audio.stopStandaloneCapture();
      await _subscription?.cancel();
      _playbackTimer?.cancel();
      _playbackFlushTimer?.cancel();
      _fishProcessTimer?.cancel();
      _uiRefreshTimer?.cancel();
      _playbackQueue.clear();
      await Future.wait([
        _phoneOpenAi.disconnect(),
        _headsetOpenAi.disconnect(),
        _phoneGemini.disconnect(),
        _headsetGemini.disconnect(),
        _phoneFish.disconnect(),
        _headsetFish.disconnect()
      ]);
      if (mounted) {
        setState(() {
          _running = false;
          _status = const _StandaloneStatus.ready();
        });
      }
      return;
    }
    final l10n = AppLocalizations.of(context);
    final config = context.read<ProviderConfigService>().config;
    final sessionService = context.read<SessionService>();
    final audioPolicy = context.read<AudioPolicy>();
    if (config.provider == TranslationProvider.ollama) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.standaloneNeedRealtimeProviderHint)));
      return;
    }
    if (config.provider != TranslationProvider.openAi &&
        config.apiKey.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.standaloneNeedByokKeyHint)));
      return;
    }
    setState(() => _status = const _StandaloneStatus.connecting());
    try {
      final permissionProbe = await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});
      for (final track in permissionProbe.getTracks()) {
        await track.stop();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.standaloneMicPermissionDenied)));
      }
      return;
    }
    try {
      _hasHeadset = await _audio.isHeadsetConnected();
      _audioDiagnostics = await _audio.getAudioDiagnostics();
      if (config.provider == TranslationProvider.openAi) {
        final usesClientSecret = config.apiKey.trim().isEmpty;
        final openAiCredential = usesClientSecret
            ? await sessionService
                .fetchOpenAiClientSecret(_languageCodes[_headsetLanguage]!)
            : config.apiKey.trim();
        if (openAiCredential == null || openAiCredential.isEmpty) {
          throw StateError(l10n.standaloneClientSecretFailed);
        }
        final openAiConnections = <Future<void>>[
          _phoneOpenAi.connect(
              apiKey: openAiCredential,
              targetLanguage: _languageCodes[_headsetLanguage]!,
              credentialRefresher: usesClientSecret
                  ? () => sessionService.fetchOpenAiClientSecret(
                      _languageCodes[_headsetLanguage]!)
                  : null),
        ];
        if (_hasHeadset) {
          openAiConnections.add(_headsetOpenAi.connect(
              apiKey: openAiCredential,
              targetLanguage: _languageCodes[_phoneLanguage]!,
              credentialRefresher: usesClientSecret
                  ? () => sessionService
                      .fetchOpenAiClientSecret(_languageCodes[_phoneLanguage]!)
                  : null));
        }
        await Future.wait(openAiConnections);
      } else if (config.provider == TranslationProvider.geminiLive) {
        final geminiConnections = <Future<void>>[
          _phoneGemini.connect(
              apiKey: config.apiKey,
              targetLanguage: _languageCodes[_headsetLanguage]!,
              model: config.model),
        ];
        if (_hasHeadset) {
          geminiConnections.add(_headsetGemini.connect(
              apiKey: config.apiKey,
              targetLanguage: _languageCodes[_phoneLanguage]!,
              model: config.model));
        }
        await Future.wait(geminiConnections);
      } else {
        final fishConnections = <Future<void>>[
          _phoneFish.connect(
              apiKey: config.apiKey,
              voiceId: config.voiceId,
              latency: config.latencyMode,
              model: config.model,
              temperature: config.temperature,
              topP: config.topP,
              speed: config.speed),
        ];
        if (_hasHeadset) {
          fishConnections.add(_headsetFish.connect(
              apiKey: config.apiKey,
              voiceId: config.voiceId,
              latency: config.latencyMode,
              model: config.model,
              temperature: config.temperature,
              topP: config.topP,
              speed: config.speed));
        }
        await Future.wait(fishConnections);
      }
      final ok = await _audio.startStandaloneCapture(
        aecEnabled: audioPolicy.output != AudioOutput.headset ||
            audioPolicy.forceEchoGuard,
        noiseSuppressionEnabled: true,
      );
      if (!mounted) return;
      if (!ok) {
        await Future.wait([
          _phoneOpenAi.disconnect(),
          _headsetOpenAi.disconnect(),
          _phoneGemini.disconnect(),
          _headsetGemini.disconnect(),
          _phoneFish.disconnect(),
          _headsetFish.disconnect()
        ]);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.standaloneDualMicStartFailed)));
        return;
      }
      _audioDiagnostics = await _audio.getAudioDiagnostics();
      if (config.provider == TranslationProvider.fishAudio) {
        _fishPlaybackPrebuffer = true;
        _fishProcessTimer = Timer.periodic(const Duration(milliseconds: 1200),
            (_) => _processFishAudio(config));
      }
      _subscription = _audio.standaloneStream?.listen((frame) {
        if (!mounted) return;
        _lastSourceKey = frame['source'] == 'phone' ? 'phone' : 'headset';
        _sourceFrames++;
        _lastFrameAt = DateTime.now();
        final bytes = frame['bytes'] as Uint8List;
        final rate = frame['sampleRate'] as int? ?? 16000;
        if (config.provider == TranslationProvider.openAi) {
          (frame['source'] == 'phone' ? _phoneOpenAi : _headsetOpenAi)
              .sendPcm16(bytes, inputSampleRate: rate);
        } else if (config.provider == TranslationProvider.geminiLive) {
          (frame['source'] == 'phone' ? _phoneGemini : _headsetGemini)
              .sendPcm16(bytes);
        } else {
          final source = frame['source'] as String;
          (_fishBuffers[source] ??= BytesBuilder(copy: false)).add(bytes);
        }
      });
      _playbackTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        final ownerHeadphoneChunks =
            config.provider == TranslationProvider.openAi
                ? _phoneOpenAi.takeAudioChunks()
                : config.provider == TranslationProvider.geminiLive
                    ? _phoneGemini.takeAudioChunks()
                    : _phoneFish.takeAudioChunks();
        final otherSpeakerChunks = config.provider == TranslationProvider.openAi
            ? _headsetOpenAi.takeAudioChunks()
            : config.provider == TranslationProvider.geminiLive
                ? _headsetGemini.takeAudioChunks()
                : _headsetFish.takeAudioChunks();
        for (final chunk in ownerHeadphoneChunks) {
          _enqueuePlayback(
              chunk, _hasHeadset ? AudioOutput.headset : AudioOutput.speaker);
        }
        for (final chunk in otherSpeakerChunks) {
          _enqueuePlayback(chunk, AudioOutput.speaker);
        }
      });
      setState(() {
        _running = true;
        _status = _StandaloneStatus.active(singleMic: !_hasHeadset);
      });
      _uiRefreshTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || !_running) return;
        final states = config.provider == TranslationProvider.openAi
            ? <String>[
                _phoneOpenAi.state,
                if (_hasHeadset) _headsetOpenAi.state,
              ]
            : config.provider == TranslationProvider.geminiLive
                ? <String>[
                    _phoneGemini.isConnected ? 'ready' : 'degraded',
                    if (_hasHeadset)
                      _headsetGemini.isConnected ? 'ready' : 'degraded',
                  ]
                : <String>[
                    _phoneFish.state,
                    if (_hasHeadset) _headsetFish.state,
                  ];
        final stale = _lastFrameAt == null ||
            DateTime.now().difference(_lastFrameAt!).inMilliseconds > 2000;
        final _StandaloneStatus next =
            states.contains('degraded') || states.contains('error')
                ? _StandaloneStatus.reconnecting(config.provider.displayName)
                : stale
                    ? const _StandaloneStatus.connectedWaiting()
                    : _StandaloneStatus.active(singleMic: !_hasHeadset);
        setState(() => _status = next);
      });
    } catch (error) {
      await Future.wait([
        _phoneOpenAi.disconnect(),
        _headsetOpenAi.disconnect(),
        _phoneGemini.disconnect(),
        _headsetGemini.disconnect(),
        _phoneFish.disconnect(),
        _headsetFish.disconnect()
      ]);
      if (mounted) {
        setState(() => _status = _StandaloneStatus.connectionFailed(
            config.provider.displayName));
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _playbackTimer?.cancel();
    _playbackFlushTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _fishProcessTimer?.cancel();
    _playbackQueue.clear();
    _fishPlaybackPrebuffer = false;
    _audio.stopStandaloneCapture();
    _phoneOpenAi.dispose();
    _headsetOpenAi.dispose();
    _phoneGemini.dispose();
    _headsetGemini.dispose();
    _phoneFish.dispose();
    _headsetFish.dispose();
    super.dispose();
  }

  Future<void> _processFishAudio(ProviderConfig config) async {
    for (final source in const ['phone', 'headset']) {
      final buffer = _fishBuffers[source];
      if (buffer == null ||
          buffer.length < 16000 * 2 ||
          _fishBusy[source] == true) {
        continue;
      }
      _fishBusy[source] = true;
      final pcm = buffer.takeBytes();
      try {
        final sourceLanguage = source == 'phone'
            ? _languageCodes[_phoneLanguage]!
            : _languageCodes[_headsetLanguage]!;
        final targetLanguage = source == 'phone'
            ? _languageCodes[_headsetLanguage]!
            : _languageCodes[_phoneLanguage]!;
        final transcript = await _fishAsr.transcribe(
            apiKey: config.apiKey,
            pcm16: pcm,
            sampleRate: 16000,
            language: sourceLanguage);
        if (transcript.isNotEmpty) {
          final result = await _translator.translate(
              text: transcript,
              sourceLang: sourceLanguage,
              targetLang: targetLanguage,
              config: config);
          if (!result.translated) {
            // Never speak the source text back: it sounds like a working
            // translation while nothing was translated at all.
            if (mounted) {
              setState(() =>
                  _status = _StandaloneStatus.noTranslation(result.reason!));
            }
            continue;
          }
          final output = source == 'phone' ? _phoneFish : _headsetFish;
          output.sendText(result.text);
          output.flush();
        }
      } catch (error) {
        if (mounted) {
          setState(() =>
              _status = _StandaloneStatus.fishError(error.toString()));
        }
      } finally {
        _fishBusy[source] = false;
      }
    }
  }

  void _enqueuePlayback(Uint8List bytes, AudioOutput output) {
    if (bytes.isEmpty) return;
    if (_playbackQueue.length >= _maxPlaybackQueue) {
      // Drop the oldest not-yet-played chunk to keep latency bounded.
      _playbackQueue.removeAt(0);
    }
    _playbackQueue.add(_PlaybackChunk(bytes, output));
    _playbackFlushTimer?.cancel();
    _playbackFlushTimer = Timer(const Duration(milliseconds: 180), () {
      _playbackFlushTimer = null;
      _drainPlaybackQueue(force: true);
    });
    _drainPlaybackQueue();
  }

  Future<void> _drainPlaybackQueue({bool force = false}) async {
    if (_playbackDraining) return;
    if (_fishPlaybackPrebuffer && !force && _playbackQueue.length < 2) return;
    _playbackDraining = true;
    try {
      while (mounted && _playbackQueue.isNotEmpty) {
        final next = _playbackQueue.removeAt(0);
        await _audio.playPcm16(next.bytes, output: next.output);
      }
    } finally {
      _playbackDraining = false;
      if (mounted && _playbackQueue.isNotEmpty) {
        _drainPlaybackQueue();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = _audioDiagnostics['aecActive'] == true
        ? l10n.standaloneActive
        : l10n.standaloneInactive;
    final nsActive = _audioDiagnostics['noiseSuppressionActive'] == true
        ? l10n.standaloneActive
        : l10n.standaloneInactive;
    final lastSourceText = switch (_lastSourceKey) {
      'phone' => l10n.standalonePhoneMic,
      'headset' => l10n.standaloneHeadsetMic,
      _ => l10n.standaloneNoSourceYet,
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.standaloneTitle)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(l10n.standaloneHeadline,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(l10n.standaloneExplanation),
        const SizedBox(height: 20),
        Consumer<ProviderConfigService>(
          builder: (_, service, __) => Card(
            child: ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: Text(l10n.standaloneTranslationProvider),
              subtitle: Text(service.config.provider.displayName),
            ),
          ),
        ),
        _language(l10n.standalonePhoneMicPartner, _phoneLanguage,
            (v) => setState(() => _phoneLanguage = v!)),
        _language(l10n.standaloneHeadsetMicUser, _headsetLanguage,
            (v) => setState(() => _headsetLanguage = v!)),
        const SizedBox(height: 20),
        Card(
            child: ListTile(
                leading: Icon(_running ? Icons.mic : Icons.mic_off),
                title: Text(_status.text(l10n)),
                subtitle: Text(l10n.standaloneFrameSummary(
                    lastSourceText,
                    _sourceFrames,
                    _hasHeadset ? '' : l10n.standaloneNoHeadsetSuffix)))),
        if (_audioDiagnostics.isNotEmpty)
          Card(
              child: ListTile(
                  leading: const Icon(Icons.settings_input_component),
                  title: Text(_audioDiagnostics['outputRoute']?.toString() ??
                      l10n.standaloneUnknownAudioRoute),
                  subtitle: Text(l10n.standaloneAecNsSummary(active, nsActive)))),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: _toggle,
            icon: Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(_running
                ? l10n.standaloneStopTranslation
                : l10n.standaloneStartTranslation)),
        const SizedBox(height: 12),
        Text(l10n.standaloneSingleAudioRecordHint,
            style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Widget _language(
          String label, String value, ValueChanged<String?> onChanged) =>
      DropdownButtonFormField<String>(
          value: value,
          decoration: InputDecoration(labelText: label),
          items: const [
            'Deutsch',
            'English',
            'Français',
            'Español',
            'Italiano',
            'Türkçe',
            'Українська'
          ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: onChanged);
}

class _PlaybackChunk {
  const _PlaybackChunk(this.bytes, this.output);

  final Uint8List bytes;
  final AudioOutput output;
}

/// The status line's semantic state, translated at display time in build().
class _StandaloneStatus {
  const _StandaloneStatus.ready() : _kind = 'ready', _arg = null;
  const _StandaloneStatus.connecting() : _kind = 'connecting', _arg = null;
  const _StandaloneStatus.active({required bool singleMic})
      : _kind = singleMic ? 'activeSingleMic' : 'active',
        _arg = null;
  const _StandaloneStatus.reconnecting(String provider)
      : _kind = 'reconnecting',
        _arg = provider;
  const _StandaloneStatus.connectedWaiting()
      : _kind = 'connectedWaiting',
        _arg = null;
  const _StandaloneStatus.connectionFailed(String provider)
      : _kind = 'connectionFailed',
        _arg = provider;
  const _StandaloneStatus.noTranslation(String reason)
      : _kind = 'noTranslation',
        _arg = reason;
  const _StandaloneStatus.fishError(String error)
      : _kind = 'fishError',
        _arg = error;

  final String _kind;
  final String? _arg;

  String text(AppLocalizations l10n) => switch (_kind) {
        'ready' => l10n.standaloneStatusReady,
        'connecting' => l10n.standaloneStatusConnecting,
        'active' => l10n.standaloneStatusActive,
        'activeSingleMic' => l10n.standaloneStatusActiveSingleMic,
        'reconnecting' => l10n.standaloneStatusReconnecting(_arg!),
        'connectedWaiting' => l10n.standaloneStatusConnectedWaiting,
        'connectionFailed' => l10n.standaloneStatusConnectionFailed(_arg!),
        'noTranslation' => l10n.sessionNoTranslation(_arg!),
        'fishError' => l10n.standaloneStatusFishError(_arg!),
        _ => '',
      };
}
