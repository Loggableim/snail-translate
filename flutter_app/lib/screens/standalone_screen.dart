import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../l10n/app_localizations.dart';
import '../models/translation_languages.dart';
import '../services/snail_audio.dart';
import '../services/speech_turn_buffer.dart';
import '../services/live_translation_provider.dart';
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
  final _audio = SnailAudio();
  final _phoneOpenAi = OpenAiRealtimeService();
  final _headsetOpenAi = OpenAiRealtimeService();
  final _phoneGemini = GeminiLiveService();
  final _headsetGemini = GeminiLiveService();
  final _phoneFish = FishAudioRealtimeService();
  final _headsetFish = FishAudioRealtimeService();
  final _fishAsr = FishAudioAsrService();
  final _translator = TranslationService();
  // Turn-aware buffers per source: the gate decides where a turn starts and
  // ends instead of slicing fixed 1 s windows that cut words in half.
  final Map<String, SpeechTurnBuffer> _fishTurns = <String, SpeechTurnBuffer>{};
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
  // Languages are stored as ISO codes and resolved through the shared
  // translationLanguages list, so the quick translator offers exactly the
  // same set as the session screen.
  String _phoneLanguage = 'de';
  String _headsetLanguage = 'en';
  // Raw state rather than pre-translated text, so the locale can change
  // (or the widget can simply be localized) without stale strings sticking
  // around in State fields declared before a BuildContext exists.
  String? _lastSourceKey;
  _StandaloneStatus _status = const _StandaloneStatus.ready();
  int _sourceFrames = 0;
  DateTime? _lastFrameAt;
  bool _hasHeadset = false;
  Map<String, dynamic> _audioDiagnostics = const <String, dynamic>{};
  // Live transcripts per side, for the split conversation view. Keyed by
  // 'phone' (partner side) and 'headset' (user side); each entry holds the
  // last source text and its translation.
  final Map<String, _LiveTranscript> _liveTranscripts =
      <String, _LiveTranscript>{};

  // Live transcript listeners for the split conversation view. The same
  // listener instance must be passed to addListener and removeListener.
  void _phoneTranscriptListener() {
    final config = context.read<ProviderConfigService>().config;
    if (config.provider == TranslationProvider.openAi) {
      _updateLiveTranscript('phone', _phoneOpenAi);
    } else {
      _updateLiveTranscript('phone', _phoneGemini);
    }
  }

  void _headsetTranscriptListener() {
    final config = context.read<ProviderConfigService>().config;
    if (config.provider == TranslationProvider.openAi) {
      _updateLiveTranscript('headset', _headsetOpenAi);
    } else {
      _updateLiveTranscript('headset', _headsetGemini);
    }
  }

  void _updateLiveTranscript(String source, LiveTranslationProvider provider) {
    if (!mounted) return;
    final input = provider.inputTranscript.trim();
    final output = provider.outputTranscript.trim();
    final current = _liveTranscripts[source];
    if (current != null &&
        current.source == input &&
        current.translation == output) {
      return;
    }
    setState(() {
      _liveTranscripts[source] = _LiveTranscript(
        source: input,
        translation: output,
      );
    });
  }

  /// Changes a side's language while the session is running. The live
  /// providers bind the target language to their websocket session, so the
  /// affected connections must be re-established; the native microphone
  /// capture keeps running throughout, so no audio is lost.
  ///
  /// Direction mapping: each side's provider session translates INTO the
  /// other side's language, so changing side X's language reconnects side
  /// Y's session — a partner (phone) language change reconnects the HEADSET
  /// session, a user (headset) language change reconnects the PHONE session.
  Future<void> _changeLanguageLive(String side, String newLanguage) async {
    final previous = side == 'phone' ? _phoneLanguage : _headsetLanguage;
    if (previous == newLanguage) return;
    setState(() {
      if (side == 'phone') {
        _phoneLanguage = newLanguage;
      } else {
        _headsetLanguage = newLanguage;
      }
      _status = const _StandaloneStatus.connecting();
    });
    final config = context.read<ProviderConfigService>().config;
    final sessionService = context.read<SessionService>();
    final reconnectHeadset = side == 'phone';
    try {
      if (config.provider == TranslationProvider.openAi) {
        final usesClientSecret = config.apiKey.trim().isEmpty;
        if (reconnectHeadset && _hasHeadset) {
          // The partner's language changed: the HEADSET session translates
          // the user's speech INTO the partner's language, so it is the one
          // that must be re-established with the new target.
          await _headsetOpenAi.disconnect();
          _headsetOpenAi.removeListener(_headsetTranscriptListener);
          final credential = usesClientSecret
              ? await sessionService.fetchOpenAiClientSecret(_phoneLanguage)
              : config.apiKey.trim();
          if (credential == null || credential.isEmpty) {
            throw StateError('credential');
          }
          await _headsetOpenAi.connect(
              apiKey: credential,
              targetLanguage: _phoneLanguage,
              credentialRefresher: usesClientSecret
                  ? () => sessionService
                      .fetchOpenAiClientSecret(_phoneLanguage)
                  : null);
          _headsetOpenAi.addListener(_headsetTranscriptListener);
        } else if (!reconnectHeadset) {
          // The user's language changed: the PHONE session translates the
          // partner's speech INTO the user's language. It is the only
          // session in single-mic mode, so it reconnects with or without a
          // headset.
          await _phoneOpenAi.disconnect();
          _phoneOpenAi.removeListener(_phoneTranscriptListener);
          final credential = usesClientSecret
              ? await sessionService.fetchOpenAiClientSecret(_headsetLanguage)
              : config.apiKey.trim();
          if (credential == null || credential.isEmpty) {
            throw StateError('credential');
          }
          await _phoneOpenAi.connect(
              apiKey: credential,
              targetLanguage: _headsetLanguage,
              credentialRefresher: usesClientSecret
                  ? () => sessionService
                      .fetchOpenAiClientSecret(_headsetLanguage)
                  : null);
          _phoneOpenAi.addListener(_phoneTranscriptListener);
        }
      } else if (config.provider == TranslationProvider.geminiLive) {
        if (reconnectHeadset && _hasHeadset) {
          await _headsetGemini.disconnect();
          _headsetGemini.removeListener(_headsetTranscriptListener);
          await _headsetGemini.connect(
              apiKey: config.apiKey,
              targetLanguage: _phoneLanguage,
              model: config.model);
          _headsetGemini.addListener(_headsetTranscriptListener);
        } else if (!reconnectHeadset) {
          await _phoneGemini.disconnect();
          _phoneGemini.removeListener(_phoneTranscriptListener);
          await _phoneGemini.connect(
              apiKey: config.apiKey,
              targetLanguage: _headsetLanguage,
              model: config.model);
          _phoneGemini.addListener(_phoneTranscriptListener);
        }
      }
      // Fish has no per-connection language: the pipeline reads the
      // current _phoneLanguage/_headsetLanguage on every turn, so nothing
      // needs reconnecting.
      if (mounted) {
        setState(() => _status =
            _StandaloneStatus.active(singleMic: !_hasHeadset));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (side == 'phone') {
            _phoneLanguage = previous;
          } else {
            _headsetLanguage = previous;
          }
          _status = _StandaloneStatus.connectionFailed(
              config.provider.displayName);
        });
      }
    }
  }

  Future<void> _toggle() async {
    if (_running) {
      await _audio.stopStandaloneCapture();
      await _subscription?.cancel();
      _playbackTimer?.cancel();
      _playbackFlushTimer?.cancel();
      _fishProcessTimer?.cancel();
      _uiRefreshTimer?.cancel();
      _playbackQueue.clear();
      _fishTurns.clear();
      _liveTranscripts.clear();
      _phoneOpenAi.removeListener(_phoneTranscriptListener);
      _headsetOpenAi.removeListener(_headsetTranscriptListener);
      _phoneGemini.removeListener(_phoneTranscriptListener);
      _headsetGemini.removeListener(_headsetTranscriptListener);
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
                .fetchOpenAiClientSecret(_headsetLanguage)
            : config.apiKey.trim();
        if (openAiCredential == null || openAiCredential.isEmpty) {
          throw StateError(l10n.standaloneClientSecretFailed);
        }
        final openAiConnections = <Future<void>>[
          _phoneOpenAi.connect(
              apiKey: openAiCredential,
              targetLanguage: _headsetLanguage,
              credentialRefresher: usesClientSecret
                  ? () => sessionService.fetchOpenAiClientSecret(
                      _headsetLanguage)
                  : null),
        ];
        if (_hasHeadset) {
          openAiConnections.add(_headsetOpenAi.connect(
              apiKey: openAiCredential,
              targetLanguage: _phoneLanguage,
              credentialRefresher: usesClientSecret
                  ? () => sessionService
                      .fetchOpenAiClientSecret(_phoneLanguage)
                  : null));
        }
        await Future.wait(openAiConnections);
        // Live transcript listeners for the split conversation view.
        _phoneOpenAi.addListener(_phoneTranscriptListener);
        if (_hasHeadset) {
          _headsetOpenAi.addListener(_headsetTranscriptListener);
        }
      } else if (config.provider == TranslationProvider.geminiLive) {
        final geminiConnections = <Future<void>>[
          _phoneGemini.connect(
              apiKey: config.apiKey,
              targetLanguage: _headsetLanguage,
              model: config.model),
        ];
        if (_hasHeadset) {
          geminiConnections.add(_headsetGemini.connect(
              apiKey: config.apiKey,
              targetLanguage: _phoneLanguage,
              model: config.model));
        }
        await Future.wait(geminiConnections);
        _phoneGemini.addListener(_phoneTranscriptListener);
        if (_hasHeadset) {
          _headsetGemini.addListener(_headsetTranscriptListener);
        }
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
        _fishTurns.clear();
        _fishTurns['phone'] = SpeechTurnBuffer(
          gateThreshold: audioPolicy.noiseGateThreshold,
          // Match the session screen: partial turns keep a long sentence
          // translating while the speaker is still talking.
          maxTurn: const Duration(seconds: 4),
        );
        if (_hasHeadset) {
          _fishTurns['headset'] = SpeechTurnBuffer(
            gateThreshold: audioPolicy.noiseGateThreshold,
            maxTurn: const Duration(seconds: 4),
          );
        }
        _fishProcessTimer = Timer.periodic(const Duration(milliseconds: 250),
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
          final turns = _fishTurns[source];
          if (turns != null) turns.add(bytes, DateTime.now());
        }
      });
      _playbackTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        // Channel routing, the core of the two-person quick translator:
        //   phone mic (partner)   -> translated audio to the HEADSET wearer
        //   headset mic (user)    -> translated audio to the SPEAKER (partner)
        // Each person hears only the other's translation on their own output,
        // never their own voice echoed back.
        final phoneMicTranslationChunks =
            config.provider == TranslationProvider.openAi
                ? _phoneOpenAi.takeAudioChunks()
                : config.provider == TranslationProvider.geminiLive
                    ? _phoneGemini.takeAudioChunks()
                    : _phoneFish.takeAudioChunks();
        final headsetMicTranslationChunks =
            config.provider == TranslationProvider.openAi
                ? _headsetOpenAi.takeAudioChunks()
                : config.provider == TranslationProvider.geminiLive
                    ? _headsetGemini.takeAudioChunks()
                    : _headsetFish.takeAudioChunks();
        for (final chunk in phoneMicTranslationChunks) {
          _enqueuePlayback(
              chunk, _hasHeadset ? AudioOutput.headset : AudioOutput.speaker);
        }
        for (final chunk in headsetMicTranslationChunks) {
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
    } catch (_) {
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
            .showSnackBar(SnackBar(content: Text(l10n.commonError)));
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
    unawaited(_audio.dispose());
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
      final turns = _fishTurns[source];
      if (turns == null || _fishBusy[source] == true) continue;
      if (!turns.isTurnComplete(DateTime.now())) continue;
      final pcm = turns.takeTurn();
      if (pcm == null) continue;
      _fishBusy[source] = true;
      try {
        final sourceLanguage = source == 'phone'
            ? _phoneLanguage
            : _headsetLanguage;
        final targetLanguage = source == 'phone'
            ? _headsetLanguage
            : _phoneLanguage;
        final transcript = await _fishAsr.transcribe(
            apiKey: config.apiKey,
            pcm16: pcm,
            sampleRate: 16000,
            language: sourceLanguage);
        // Fish ASR hallucinates whole sentences when it receives echo, noise
        // or silence (on-device: Chinese lyrics in a German/English
        // conversation). Reject implausible scripts before translating and
        // speaking them — a wrong-language invention is worse than silence.
        if (transcript.isNotEmpty &&
            FishAudioAsrService.isImplausibleTranscript(
                transcript, sourceLanguage)) {
          continue;
        }
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
              setState(() => _status = _StandaloneStatus.noTranslation(
                  result.localizedReason(AppLocalizations.of(context))));
            }
            continue;
          }
          final output = source == 'phone' ? _phoneFish : _headsetFish;
          output.sendText(result.text);
          output.flush();
          // Feed the split conversation view: source text + translation.
          if (mounted) {
            setState(() => _liveTranscripts[source] = _LiveTranscript(
                source: transcript, translation: result.text));
          }
        }
      } catch (error) {
        if (mounted) {
          setState(() =>
        _status = _StandaloneStatus.fishError(
            AppLocalizations.of(context).commonError));
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
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.standaloneTitle),
        actions: [
          // Device status: which microphone pair is active. Tapping opens the
          // audio diagnostics from the setup view (via stop/restart is not
          // needed — the icon only reports the current capture state).
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
              _hasHeadset ? Icons.headset_rounded : Icons.phone_in_talk_rounded,
              size: 20,
              color: _hasHeadset ? Colors.green : colors.primary,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                _status.text(l10n),
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
      // While translating, the screen becomes the conversation table: the
      // top half faces the partner (rotated 180°), the bottom half faces
      // the user, each showing the other side's live translation.
      body: _running ? _buildConversationView(context, l10n) : _buildSetupView(context, l10n),
    );
  }

  /// Setup view: languages, provider, start button (the previous layout).
  Widget _buildSetupView(BuildContext context, AppLocalizations l10n) {
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
    return ListView(padding: const EdgeInsets.all(20), children: [
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
      ],
    );
  }

  /// The conversation view: top half rotated 180° for the partner sitting
  /// across the table, bottom half for the headset user. Each half shows the
  /// other person's live translation to read along, with an inline language
  /// picker so the pair can switch languages without stopping.
  Widget _buildConversationView(BuildContext context, AppLocalizations l10n) {
    final colors = Theme.of(context).colorScheme;
    // Each person reads the OTHER side's speech, translated into their own
    // language: the partner reads the user's turns (translated into
    // _phoneLanguage), the user reads the partner's turns (translated into
    // _headsetLanguage). Showing a side its own speech would make both
    // halves echo the speaker instead of the conversation partner.
    final partnerReads = _liveTranscripts['headset'];
    final userReads = _liveTranscripts['phone'];
    Widget half({
      required String title,
      required String side,
      required String languageCode,
      required _LiveTranscript? transcript,
      required bool flipped,
    }) {
      final translation =
          transcript == null || transcript.translation.isEmpty
              ? l10n.standaloneSplitNoSpeech
              : transcript.translation;
      final original = (transcript == null || transcript.source.isEmpty)
          ? null
          : transcript.source;
      return Expanded(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          child: RotatedBox(
            quarterTurns: flipped ? 2 : 0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: colors.primary,
                        )),
                    const Spacer(),
                    // Inline language picker: switching reconnects only the
                    // affected provider session; the mic capture keeps
                    // running, so the conversation can continue mid-sentence.
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: languageCode,
                        isDense: true,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: colors.onSurface,
                        ),
                        icon: Icon(Icons.arrow_drop_down,
                            size: 20,
                            color: colors.onSurface.withValues(alpha: .5)),
                        items: translationLanguages
                            .map((language) => DropdownMenuItem(
                                  value: language.code,
                                  child: Text(language.native),
                                ))
                            .toList(),
                        onChanged: _running
                            ? (value) {
                                if (value != null) {
                                  _changeLanguageLive(side, value);
                                }
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  translation,
                  style: TextStyle(
                    fontSize: 22,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                if (original != null && original != translation) ...[
                  const SizedBox(height: 6),
                  Text(
                    original,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurface.withValues(alpha: .45),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        // Partner half — faces the person across the table, upside down.
        // The partner reads the USER's speech (headset mic) translated into
        // the partner's language, and their picker changes that language.
        half(
          title: l10n.standaloneSplitPartner,
          side: 'phone',
          languageCode: _phoneLanguage,
          transcript: partnerReads,
          flipped: true,
        ),
        Divider(height: 1, color: colors.outline.withValues(alpha: .3)),
        // User half — faces the headset wearer. The user reads the PARTNER's
        // speech (phone mic) translated into the user's language.
        half(
          title: l10n.standaloneSplitUser,
          side: 'headset',
          languageCode: _headsetLanguage,
          transcript: userReads,
          flipped: false,
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: _toggle,
              icon: const Icon(Icons.stop),
              label: Text(l10n.standaloneStopTranslation),
            ),
          ),
        ),
      ],
    );
  }

  Widget _language(
          String label, String value, ValueChanged<String?> onChanged) =>
      DropdownButtonFormField<String>(
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: translationLanguages
              .map((language) => DropdownMenuItem(
                  value: language.code,
                  child: Text(language.native)))
              .toList(),
          onChanged: onChanged);
}

class _PlaybackChunk {
  const _PlaybackChunk(this.bytes, this.output);

  final Uint8List bytes;
  final AudioOutput output;
}

/// One side's latest live transcript pair for the split conversation view.
class _LiveTranscript {
  const _LiveTranscript({required this.source, required this.translation});

  final String source;
  final String translation;
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
