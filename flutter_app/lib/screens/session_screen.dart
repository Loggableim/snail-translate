import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/session_service.dart';
import '../services/audio_service.dart';
import '../services/snail_audio.dart';
import '../services/gemini_live_service.dart';
import '../services/provider_config_service.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../services/openai_realtime_service.dart';
import '../services/fish_audio_asr_service.dart';
import '../services/fish_audio_realtime_service.dart';
import '../services/translation_service.dart';
import '../services/p2p_audio_service.dart';
import '../services/user_identity_service.dart';
import '../services/transcript_history.dart';
import '../services/audio_policy.dart';
import '../services/audio_processor.dart';
import '../services/speech_turn_buffer.dart';
import '../services/error_logger.dart';
import 'chat_screen.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionPlaybackChunk {
  const _SessionPlaybackChunk(this.bytes, this.sampleRate);

  final Uint8List bytes;
  final int sampleRate;
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  String _levelDb(double level) =>
      AudioProcessor.levelToDbfs(level).toStringAsFixed(0);

  // Cache provider-owned services before the route starts unmounting. Reading
  // an inherited provider from dispose() can race with Provider's own teardown
  // and trigger Flutter's `_dependents.isEmpty` assertion.
  late final AudioService _audioService;
  late final SessionService _sessionService;
  late final TranscriptHistory _transcriptHistory;
  late final AudioPolicy _audioPolicy;
  final _snailAudio = SnailAudio();
  StreamSubscription? _audioSubscription;
  final _micLevel = ValueNotifier<double>(0.0);
  bool _clippingDetected = false;
  GeminiLiveService? _gemini;
  OpenAiRealtimeService? _openAi;
  OpenAiRealtimeService? _guestFallbackOpenAi;
  FishAudioRealtimeService? _fish;
  final _fishAsr = FishAudioAsrService();
  final _translator = TranslationService();
  SpeechTurnBuffer? _fishTurns;
  Timer? _fishProcessTimer;
  bool _fishBusy = false;
  int _fishCaptureChunks = 0;
  bool _fishRelayAudioOnly = false;
  VoidCallback? _fishListener;
  String _fishSourceLanguage = 'en';
  String _fishTargetLanguage = 'de';
  String _sessionTargetLanguage = 'en';
  final _p2p = P2pAudioService();
  VoidCallback? _geminiListener;
  VoidCallback? _openAiListener;
  VoidCallback? _guestFallbackOpenAiListener;
  bool _openAiPlaybackRunning = false;
  bool _fallbackPlaybackRunning = false;
  bool _sessionPlaybackPrimed = false;
  final List<_SessionPlaybackChunk> _playbackQueue = <_SessionPlaybackChunk>[];
  bool _playbackDraining = false;
  static const _maxPlaybackQueue = 24;
  static const _sessionPrebufferChunks = 4;
  /// How long a partially filled prebuffer may wait before it plays anyway.
  static const _playbackPrimeTimeout = Duration(milliseconds: 220);
  Timer? _playbackPrimeTimer;
  Future<void>? _guestFallbackConnecting;
  int _lastOpenAiSpeechStarts = 0;
  int _connectionGeneration = 0;

  static const _languageLabels = <String, String>{
    'de': 'Deutsch',
    'en': 'English',
    'fr': 'Francais',
    'es': 'Espanol',
    'it': 'Italiano',
    'ja': '日本語',
    'ko': '한국어',
    'zh': '中文',
    'uk': 'Українська',
    'ar': 'Arabic',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'nl': 'Dutch',
    'tr': 'Turkish',
    'hi': 'Hindi',
    'vi': 'Vietnamese',
    'pl': 'Polish',
    'sv': 'Swedish',
  };

  static const _fishVoices = <String, String>{
    '802e3bc2b27e49c2995d23ef70e6ac89': 'Standard Snail',
    '2d4039641d67419fa132ca59fa2f61ad': 'Cid',
    '42039da0dcbd49bc8846fc1c12def1f4': 'Mr. Fox',
  };

  Future<void> _selectFishVoice(String? voiceId) async {
    if (voiceId == null) return;
    final service = context.read<ProviderConfigService>();
    final current = service.config;
    await service.save(ProviderConfig(
      provider: current.provider,
      endpoint: current.endpoint,
      model: current.model,
      chatModel: current.chatModel,
      apiKey: current.apiKey,
      voiceId: voiceId,
      latencyMode: current.latencyMode,
      temperature: current.temperature,
      topP: current.topP,
      speed: current.speed,
      translationEndpoint: current.translationEndpoint,
      translationModel: current.translationModel,
    ));
    if (_fish != null &&
        service.config.provider == TranslationProvider.fishAudio) {
      await _fish!.changeVoice(voiceId);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Fish-Stimme für deine Ausgabe: ${_fishVoices[voiceId] ?? voiceId}')));
    }
  }

  Future<void> _setSessionTargetLanguage(String? target) async {
    if (target == null) return;
    setState(() {
      _sessionTargetLanguage = target;
      _fishSourceLanguage = 'auto';
      _fishTargetLanguage = target;
    });
    final sessionService = context.read<SessionService>();
    await sessionService.setTargetLanguage(target);
  }

  bool _isConnectionActive(int generation) =>
      mounted && generation == _connectionGeneration;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioService = context.read<AudioService>();
    _sessionService = context.read<SessionService>();
    _sessionTargetLanguage = _sessionService.targetLanguage;
    _transcriptHistory = context.read<TranscriptHistory>();
    _audioPolicy = context.read<AudioPolicy>();
    // Keep the session alive while the user is actively translating. This is
    // intentionally scoped to the session route and released on exit.
    WakelockPlus.enable();
    unawaited(_connect(_connectionGeneration));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        // Stop capture and drain playback when app goes to background.
        _snailAudio.pauseCapture();
        _playbackPrimeTimer?.cancel();
        _playbackPrimeTimer = null;
        _playbackQueue.clear();
        _sessionPlaybackPrimed = false;
        _playbackDraining = false;
        break;
      case AppLifecycleState.resumed:
        // Resume capture when app returns to foreground.
        _snailAudio.resumeCapture();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _connect(int generation) async {
    final session = _sessionService.currentSession;
    final audioService = _audioService;
    final providerConfig = context.read<ProviderConfigService>();
    final sessionService = _sessionService;
    final openAiService = context.read<OpenAiRealtimeService>();
    final geminiService = context.read<GeminiLiveService>();
    final safetyIdentifier =
        context.read<UserIdentityService>().identity?.userId;
    if (session != null) {
      await audioService.connect(session);
      if (!_isConnectionActive(generation)) return;
      final relayAudio = audioService;
      _p2p.onSignal = (type, signal) => relayAudio.sendSignal(type, signal);
      _p2p.onAudio =
          (bytes, sampleRate) => _enqueueSessionPlayback(bytes, sampleRate);
      _p2p.onChat = relayAudio.receiveP2pData;
      relayAudio.isP2pConnected = () => _p2p.isConnected;
      relayAudio.onP2pChatSend = _p2p.sendChat;
      relayAudio.onP2pStickerSend = _p2p.sendData;
      relayAudio.onSignal = (type, signal) => _p2p.acceptSignal(type, signal);
      relayAudio.onPcmAudio = (bytes, sampleRate) {
        // Relay PCM is a fallback while ICE is negotiating.
        if (!_p2p.isConnected || _fishRelayAudioOnly) {
          _enqueueSessionPlayback(bytes, sampleRate);
        }
      };
      var p2pStarted = false;
      Future<void> startP2pAfterAuth() async {
        if (p2pStarted || !_isConnectionActive(generation)) return;
        p2pStarted = true;
        await _p2p.start(
            initiator: session.role == 'host', iceServers: session.iceServers);
      }

      relayAudio.onAuthenticated = startP2pAfterAuth;
      if (relayAudio.isAuthenticated) await startP2pAfterAuth();
      if (!_isConnectionActive(generation)) return;
      final initialized = await _snailAudio.initialize(sampleRate: 16000);
      if (!_isConnectionActive(generation)) return;
      if (initialized) {
        final echoGuardEnabled = _audioPolicy.output == AudioOutput.headset
            ? false
            : _audioPolicy.forceEchoGuard || _snailAudio.echoGuardEnabled;
        final provider = providerConfig.config;
        // OpenAI may use a Worker-minted short-lived secret when no local
        // BYOK key is configured. If neither exists, deliberately fall back
        // to the session owner's provider instead of failing the guest.
        String? openAiCredential;
        // `handleJoinRoom` already mirrors source/target for the guest. Both
        // devices therefore translate their own microphone into targetLang.
        final targetLanguage = _sessionTargetLanguage;
        _fishSourceLanguage = 'auto';
        _fishTargetLanguage = _sessionTargetLanguage;
        final usesWorkerClientSecret =
            provider.provider == TranslationProvider.openAi &&
                provider.apiKey.trim().isEmpty;
        if (provider.provider == TranslationProvider.openAi) {
          openAiCredential = provider.apiKey.trim().isNotEmpty
              ? provider.apiKey.trim()
              : await sessionService.fetchOpenAiClientSecret(targetLanguage);
        }
        if (!_isConnectionActive(generation)) return;
        final hasOwnLiveProvider =
            provider.provider == TranslationProvider.geminiLive
                ? provider.apiKey.trim().isNotEmpty
                : provider.provider == TranslationProvider.fishAudio
                    ? provider.apiKey.trim().isNotEmpty
                    : openAiCredential?.isNotEmpty == true;
        // A guest without a live BYOK key sends raw audio to the host. The
        // host-side live provider then returns translated pcm_audio normally.
        if (hasOwnLiveProvider && session.role == 'host') {
          relayAudio.onFallbackPcmAudio = (bytes, sampleRate) {
            // Guest fallback is a separate B→A session. It must never share
            // the Owner→Guest stream, otherwise source speakers and target
            // languages become mixed.
            if (provider.provider == TranslationProvider.openAi) {
              unawaited(_forwardGuestFallbackAudio(
                bytes,
                sampleRate,
                apiKey: openAiCredential!,
                targetLanguage: session.sourceLang,
                safetyIdentifier: safetyIdentifier,
              ));
            }
          };
        }
        // Each endpoint translates its own microphone stream when it has a
        // configured live provider. This keeps both directions parallel and
        // avoids routing the guest's speech through the host by default.
        if (hasOwnLiveProvider) {
          if (provider.provider == TranslationProvider.openAi) {
            _openAi = openAiService;
            await _openAi!.connect(
              apiKey: openAiCredential!,
              targetLanguage: targetLanguage,
              safetyIdentifier: safetyIdentifier,
              credentialRefresher: usesWorkerClientSecret
                  ? () => sessionService.fetchOpenAiClientSecret(targetLanguage)
                  : null,
            );
            if (!_isConnectionActive(generation)) return;
            _openAiListener = () {
              if (!_isConnectionActive(generation) || _openAi == null) return;
              // Clear local playback queue on reconnect to prevent double audio.
              if (_openAi!.state == 'reconnecting') {
                _playbackQueue.clear();
                _sessionPlaybackPrimed = false;
              }
              if (_openAi!.speechStarts > _lastOpenAiSpeechStarts) {
                _lastOpenAiSpeechStarts = _openAi!.speechStarts;
                // Barge-in is local and conservative: discard only audio that
                // has not entered the native player yet.
                if (echoGuardEnabled && !_audioPolicy.preferLongTurns) {
                  _openAi!.flushAudio();
                }
              }
              _persistCompletedTurns(session);
              setState(() {});
              _drainOpenAiAudio(relayAudio);
            };
            _openAi!.addListener(_openAiListener!);
            _drainOpenAiAudio(relayAudio);
            _audioSubscription = _snailAudio.audioStream?.listen((chunk) {
              // Compute mic level for visualization
              final measuredLevel = AudioProcessor.computeLevel(chunk);
              // Keep a short peak hold so brief speech is visible while the
              // 40 ms capture chunk itself is already fading out.
              _micLevel.value = measuredLevel > _micLevel.value
                  ? measuredLevel
                  : _micLevel.value * 0.86;
              // Detect clipping
              if (!_clippingDetected && AudioProcessor.detectClipping(chunk)) {
                _clippingDetected = true;
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text(
                        'Mikrofon übersteuert! Sprich etwas leiser oder '
                        'vergrößere den Abstand zum Mikrofon.',
                      ),
                      backgroundColor: Theme.of(context).colorScheme.error,
                      duration: const Duration(seconds: 4),
                      action: SnackBarAction(
                        label: 'OK',
                        textColor: Colors.white,
                        onPressed: () =>
                            ScaffoldMessenger.of(context).hideCurrentSnackBar(),
                      ),
                    ),
                  );
                }
              }
              // Do not feed the phone speaker's translated output back into
              // the realtime translator when devices are close together.
              if (!echoGuardEnabled || !_snailAudio.isPlaybackActive) {
                // Skip silent chunks to save bandwidth and API costs
                if (!AudioProcessor.detectSilence(chunk,
                    threshold: _audioPolicy.noiseGateThreshold)) {
                  _openAi!.sendPcm16(chunk);
                }
              }
            });
          } else if (provider.provider == TranslationProvider.geminiLive) {
            _gemini = geminiService;
            await _gemini!.connect(
                apiKey: provider.apiKey,
                targetLanguage: targetLanguage,
                model: provider.model);
            if (!_isConnectionActive(generation)) return;
            _geminiListener = () {
              if (!_isConnectionActive(generation) || _gemini == null) return;
              for (final chunk in _gemini!.takeAudioChunks()) {
                _enqueueSessionPlayback(chunk, 24000);
                _p2p.sendPcm16(chunk, sampleRate: 24000);
                relayAudio.sendPcmAudio(chunk, sampleRate: 24000);
              }
            };
            _gemini!.addListener(_geminiListener!);
            _audioSubscription = _snailAudio.audioStream?.listen((chunk) {
              if (!echoGuardEnabled || !_snailAudio.isPlaybackActive) {
                _gemini!.sendPcm16(chunk);
              }
            });
          } else {
            _fishRelayAudioOnly = true;
            _fish = FishAudioRealtimeService();
            await _fish!.connect(
              apiKey: provider.apiKey,
              voiceId: provider.voiceId,
              latency: provider.latencyMode,
              model: provider.model,
              temperature: provider.temperature,
              topP: provider.topP,
              speed: provider.speed,
            );
            _fishListener = _drainFishAudio;
            _fish!.addListener(_fishListener!);
            _fishTurns =
                SpeechTurnBuffer(gateThreshold: _audioPolicy.noiseGateThreshold);
            // Poll faster than the turn-silence threshold. At the old 1200 ms
            // period the end of a turn was detected anywhere between 650 ms
            // and 1850 ms after the speaker stopped; this bounds it to the
            // threshold plus one tick.
            _fishProcessTimer = Timer.periodic(
                const Duration(milliseconds: 250),
                (_) => _processFish(provider));
            _audioSubscription = _snailAudio.audioStream?.listen((chunk) {
              _fishCaptureChunks++;
              final measuredLevel = AudioProcessor.computeLevel(chunk);
              final peak = AudioProcessor.computePeak(chunk);
              _micLevel.value = measuredLevel > _micLevel.value
                  ? measuredLevel
                  : _micLevel.value * 0.86;
              final turns = _fishTurns!;
              // The gate decides where a turn starts and ends. It must not
              // decide which chunks are kept: dropping the pauses inside a
              // sentence is what made ASR return word fragments.
              turns.gateThreshold = _audioPolicy.noiseGateThreshold;
              if (!_audioService.isMuted &&
                  (!echoGuardEnabled || !_snailAudio.isPlaybackActive)) {
                turns.add(chunk, DateTime.now());
              }
              if (_fishCaptureChunks % 50 == 0) {
                debugPrint('[Snail][Fish] capture chunks=$_fishCaptureChunks bytes=${chunk.length} level=${measuredLevel.toStringAsFixed(4)} dbfs=${AudioProcessor.levelToDbfs(measuredLevel).toStringAsFixed(1)} peak=${peak.toStringAsFixed(4)} gate=${AudioProcessor.levelToDbfs(_audioPolicy.noiseGateThreshold).toStringAsFixed(1)}dBFS silent=${AudioProcessor.detectSilence(chunk, threshold: _audioPolicy.noiseGateThreshold)} buffer=${turns.bufferedBytes} speech=${turns.hasSpeech} muted=${_audioService.isMuted} playback=${_snailAudio.isPlaybackActive}');
              }
            });
          }
        } else if (!hasOwnLiveProvider) {
          _audioSubscription = _snailAudio.audioStream?.listen((chunk) {
            if (!echoGuardEnabled || !_snailAudio.isPlaybackActive) {
              relayAudio.sendFallbackPcmAudio(chunk);
            }
          });
        }
        final captureStarted = await _snailAudio.startCapture();
        if (!captureStarted || !_isConnectionActive(generation)) {
          await _snailAudio.stopCapture();
          await _snailAudio.stopSessionKeepAlive();
          return;
        }
        // Android microphone foreground services may only start after the
        // RECORD_AUDIO permission and AudioRecord have been accepted.
        await _snailAudio.startSessionKeepAlive();
      }
    }
  }

  void _persistCompletedTurns(Session session) {
    for (final turn
        in _openAi?.takeCompletedTurns() ?? const <RealtimeTurn>[]) {
      unawaited(_transcriptHistory.addEntry(
        sessionId: session.roomId,
        sourceLang: session.sourceLang,
        targetLang: session.targetLang,
        originalText: turn.sourceText,
        translatedText: turn.targetText,
        provider:
            context.read<ProviderConfigService>().config.provider.displayName,
      ));
    }
  }

  Future<void> _confirmEndSession(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Session beenden?'),
        content: const Text(
          'Bist du sicher, dass du die Session beenden möchtest? '
          'Die Verbindung wird getrennt und die Übersetzung gestoppt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Beenden'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      _audioService.disconnect();
      context.read<SessionService>().endSession();
      Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionGeneration++;
    WakelockPlus.disable();
    unawaited(_snailAudio.stopSessionKeepAlive());
    _audioSubscription?.cancel();
    _fishProcessTimer?.cancel();
    _fishRelayAudioOnly = false;
    if (_fish != null && _fishListener != null) {
      _fish!.removeListener(_fishListener!);
    }
    if (_gemini != null && _geminiListener != null) {
      _gemini!.removeListener(_geminiListener!);
    }
    if (_openAi != null && _openAiListener != null) {
      _openAi!.removeListener(_openAiListener!);
    }
    if (_guestFallbackOpenAi != null && _guestFallbackOpenAiListener != null) {
      _guestFallbackOpenAi!.removeListener(_guestFallbackOpenAiListener!);
    }
    _gemini?.disconnect();
    _openAi?.disconnect();
    _fish?.disconnect();
    _guestFallbackOpenAi?.disconnect();
    _audioService.onPcmAudio = null;
    _audioService.onFallbackPcmAudio = null;
    _audioService.onSignal = null;
    _audioService.onAuthenticated = null;
    _p2p.dispose();
    _playbackPrimeTimer?.cancel();
    _playbackPrimeTimer = null;
    _playbackQueue.clear();
    _sessionPlaybackPrimed = false;
    _snailAudio.dispose();
    _micLevel.dispose();
    _audioService.disconnect();
    super.dispose();
  }

  Future<void> _processFish(ProviderConfig config) async {
    final turns = _fishTurns;
    if (turns == null) return;
    if (_audioService.isMuted) {
      turns.reset();
      _fishBusy = false;
      return;
    }
    if (_fishBusy || !turns.isTurnComplete(DateTime.now())) return;
    final pcm = turns.takeTurn();
    if (pcm == null) return;
    _fishBusy = true;
    debugPrint('[Snail][Fish] processing buffer=${pcm.length} bytes target=$_fishTargetLanguage');
    try {
      final source = _fishSourceLanguage;
      final target = _fishTargetLanguage;
      final asrResult = await _fishAsr.transcribeDetected(
          apiKey: config.apiKey,
          pcm16: pcm,
          sampleRate: 16000,
          language: null);
      final transcript = asrResult.text;
      // Fish ASR may omit the detected language for short clips. Do not pass
      // `auto` to the fallback translator; infer the opposite language for
      // the supported DE/EN session direction until detection is available.
      final detectedSource = asrResult.language ??
          (source == 'auto'
              ? (target == 'en' ? 'de' : target == 'de' ? 'en' : 'en')
              : source);
      debugPrint('[Snail][Fish] ASR text="${transcript.substring(0, transcript.length.clamp(0, 80))}" language=${asrResult.language}');
      if (transcript.isNotEmpty && _fish != null) {
        final translated = await _translator.translate(
            text: transcript,
            sourceLang: detectedSource,
            targetLang: target,
            config: config);
        _fish!.sendText(translated);
        _fish!.flush();
        debugPrint('[Snail][Fish] TTS submitted target=$target chars=${translated.length}');
      }
    } catch (error) {
      debugPrint('[Snail][Fish] session error=$error');
      ErrorLogger.I
          .log(provider: 'fish_audio', context: 'session.audio', error: error);
    } finally {
      _fishBusy = false;
    }
  }

  void _drainFishAudio() {
    if (_audioService.isMuted || _fish == null) {
      _fish?.takeAudioChunks();
      return;
    }
    for (final chunk in _fish!.takeAudioChunks()) {
      // Fish uses the reliable relay path for complete PCM chunks. Sending
      // the same stream through WebRTC as well caused packet-loss gaps and
      // duplicate/overlapping playback on the receiver.
      _audioService.sendPcmAudio(chunk, sampleRate: 24000);
    }
  }

  Future<void> _drainOpenAiAudio(AudioService relayAudio) async {
    if (_openAiPlaybackRunning || _openAi == null) return;
    _openAiPlaybackRunning = true;
    try {
      while (mounted && _openAi != null) {
        final chunks = _openAi!.takeAudioChunks();
        if (chunks.isEmpty) break;
        for (final chunk in chunks) {
          if (!mounted) return;
          // This service translates this device's microphone for the peer.
          // Forward immediately; local monitoring would add latency and feed
          // the translated voice back into the local microphone.
          _p2p.sendPcm16(chunk, sampleRate: 24000);
          relayAudio.sendPcmAudio(chunk, sampleRate: 24000);
        }
      }
    } finally {
      _openAiPlaybackRunning = false;
      // A delta can arrive between the empty check and releasing the guard.
      if (mounted && _openAi?.hasPendingAudio == true) {
        _drainOpenAiAudio(relayAudio);
      }
    }
  }

  Future<void> _connectGuestFallbackOpenAi({
    required String apiKey,
    required String targetLanguage,
    String? safetyIdentifier,
  }) async {
    final service = OpenAiRealtimeService();
    _guestFallbackOpenAi = service;
    await service.connect(
      apiKey: apiKey,
      targetLanguage: targetLanguage,
      safetyIdentifier: safetyIdentifier,
    );
    _guestFallbackOpenAiListener = () {
      if (!mounted) return;
      setState(() {});
      _drainGuestFallbackAudio();
    };
    service.addListener(_guestFallbackOpenAiListener!);
    _drainGuestFallbackAudio();
  }

  Future<void> _forwardGuestFallbackAudio(
    Uint8List bytes,
    int sampleRate, {
    required String apiKey,
    required String targetLanguage,
    String? safetyIdentifier,
  }) async {
    try {
      _guestFallbackConnecting ??= _connectGuestFallbackOpenAi(
        apiKey: apiKey,
        targetLanguage: targetLanguage,
        safetyIdentifier: safetyIdentifier,
      );
      await _guestFallbackConnecting;
      _guestFallbackOpenAi?.sendPcm16(bytes, inputSampleRate: sampleRate);
    } catch (error, stackTrace) {
      _guestFallbackConnecting = null;
      ErrorLogger.I.log(
        provider: 'openai',
        context: 'realtime.guest-fallback',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _drainGuestFallbackAudio() async {
    if (_fallbackPlaybackRunning || _guestFallbackOpenAi == null) return;
    _fallbackPlaybackRunning = true;
    try {
      while (mounted && _guestFallbackOpenAi != null) {
        final chunks = _guestFallbackOpenAi!.takeAudioChunks();
        if (chunks.isEmpty) break;
        for (final chunk in chunks) {
          if (!mounted) return;
          _enqueueSessionPlayback(chunk, 24000);
        }
      }
    } finally {
      _fallbackPlaybackRunning = false;
      if (mounted && _guestFallbackOpenAi?.hasPendingAudio == true) {
        _drainGuestFallbackAudio();
      }
    }
  }

  void _enqueueSessionPlayback(Uint8List bytes, int sampleRate) {
    if (bytes.isEmpty) return;
    if (_playbackQueue.length >= _maxPlaybackQueue) {
      _playbackQueue.removeAt(0);
    }
    _playbackQueue.add(_SessionPlaybackChunk(bytes, sampleRate));
    // Fish/relay chunks can arrive with small network gaps. Keep a few chunks
    // in front before starting the native AudioTrack to avoid audible
    // start/stop stutter between websocket deliveries.
    if (!_sessionPlaybackPrimed &&
        _playbackQueue.length < _sessionPrebufferChunks) {
      // A short sentence, or the tail of any turn, delivers fewer chunks than
      // the prebuffer target. Without this timeout those chunks stayed queued
      // until the next turn pushed the queue over the threshold, which cut
      // the end off every utterance and replayed it late.
      _playbackPrimeTimer ??= Timer(_playbackPrimeTimeout, () {
        _playbackPrimeTimer = null;
        if (mounted && _playbackQueue.isNotEmpty) _drainSessionPlayback();
      });
      return;
    }
    _drainSessionPlayback();
  }

  Future<void> _drainSessionPlayback() async {
    if (_playbackDraining) return;
    _playbackPrimeTimer?.cancel();
    _playbackPrimeTimer = null;
    _playbackDraining = true;
    _sessionPlaybackPrimed = true;
    try {
      while (mounted && _playbackQueue.isNotEmpty) {
        final chunk = _playbackQueue.removeAt(0);
        await _snailAudio.playPcm16(chunk.bytes,
            sampleRate: chunk.sampleRate, output: _audioPolicy.output);
      }
    } finally {
      _playbackDraining = false;
      if (_playbackQueue.isEmpty) _sessionPlaybackPrimed = false;
      if (mounted && _playbackQueue.isNotEmpty) {
        _drainSessionPlayback();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final audio = context.watch<AudioService>();
    final session = context.watch<SessionService>().currentSession;
    final isHost = session?.role == 'host';

    return Scaffold(
      appBar: AppBar(
        title: Text(session?.roomId ?? 'Session'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Chat in Session öffnen',
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              builder: (_) => SizedBox(
                  height: MediaQuery.sizeOf(context).height * .86,
                  child: const ChatScreen()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              audio.isPeerConnected ? Icons.people : Icons.person,
              color: audio.isPeerConnected ? Colors.green : Colors.grey,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 650;
            final padding = compact ? 16.0 : 32.0;
            return SingleChildScrollView(
              padding: EdgeInsets.all(padding),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - padding * 2)
                      .clamp(0, double.infinity),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Status icon
                    Icon(
                      audio.isPeerConnected ? Icons.mic : Icons.mic_off,
                      size: compact ? 56 : 80,
                      color: audio.isPeerConnected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                    SizedBox(height: compact ? 12 : 24),

                    // Status text
                    Text(
                      audio.isPeerConnected
                          ? 'Verbunden — sprich jetzt!'
                          : 'Warte auf Verbindung...',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),

                    DropdownButtonFormField<String>(
                      value: _sessionTargetLanguage,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Ausgabe in',
                        prefixIcon: Icon(Icons.translate),
                        border: OutlineInputBorder(),
                      ),
                      items: _languageLabels.entries
                          .map((entry) => DropdownMenuItem<String>(
                                value: entry.key,
                                child: Text(entry.value),
                              ))
                          .toList(),
                      onChanged: _setSessionTargetLanguage,
                    ),
                    const SizedBox(height: 6),
                    ListenableBuilder(
                      listenable: _audioPolicy,
                      builder: (context, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Noise-Gate: ${_levelDb(_audioPolicy.noiseGateThreshold)} dBFS',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              ValueListenableBuilder<double>(
                                valueListenable: _micLevel,
                                builder: (context, level, _) => Text(
                                'Mikrofon: ${_levelDb(level)} dBFS',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                          ValueListenableBuilder<double>(
                            valueListenable: _micLevel,
                            builder: (context, level, _) {
                              // Full scale sits well above conversational
                              // speech (~0.08 RMS / -22 dBFS) so the bar has
                              // visible headroom before clipping.
                              const max = 0.25;
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  minHeight: 8,
                                  value: (level / max).clamp(0.0, 1.0),
                                  backgroundColor: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  color: level >=
                                          _audioPolicy.noiseGateThreshold
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                              );
                            },
                          ),
                          Slider(
                            value: _audioPolicy.noiseGateThreshold,
                            min: 0,
                            max: AudioPolicy.maxNoiseGate,
                            divisions: 20,
                            label:
                                '${_levelDb(_audioPolicy.noiseGateThreshold)} dBFS',
                            onChanged: _audioPolicy.setNoiseGateThreshold,
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              icon: const Icon(Icons.graphic_eq, size: 18),
                              label: const Text('Testton für Pegel'),
                              onPressed: () async {
                                final ok = await _snailAudio.playTestTone();
                                if (!mounted || ok) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Testton konnte nicht gestartet werden'),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      'Eingangssprache: automatisch erkannt · Ausgabe: ${_sessionTargetLanguage.toUpperCase()}',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),

                    if (context
                            .watch<ProviderConfigService>()
                            .config
                            .provider ==
                        TranslationProvider.fishAudio) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: _fishVoices.containsKey(context
                                .watch<ProviderConfigService>()
                                .config
                                .voiceId)
                            ? context
                                .watch<ProviderConfigService>()
                                .config
                                .voiceId
                            : _fishVoices.keys.first,
                        decoration: const InputDecoration(
                          labelText: 'Meine Fish-Audio-Stimme',
                          prefixIcon: Icon(Icons.record_voice_over),
                          border: OutlineInputBorder(),
                        ),
                        items: _fishVoices.entries
                            .map((entry) => DropdownMenuItem<String>(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ))
                            .toList(),
                        onChanged: _selectFishVoice,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Diese Stimme wird nur für deine übersetzte Ausgabe verwendet.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],

                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<AudioOutput>(
                            value: _audioPolicy.output,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Ausgabe',
                              prefixIcon: Icon(Icons.volume_up),
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                  value: AudioOutput.auto, child: Text('Auto')),
                              DropdownMenuItem(
                                  value: AudioOutput.speaker,
                                  child: Text('Lautsprecher')),
                              DropdownMenuItem(
                                  value: AudioOutput.headset,
                                  child: Text('Headset')),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                _audioPolicy.setOutput(value);
                                _snailAudio.setOutput(value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<AudioInput>(
                            value: AudioInput.auto,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Mikrofon',
                              prefixIcon: Icon(Icons.mic),
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                  value: AudioInput.auto, child: Text('Auto')),
                              DropdownMenuItem(
                                  value: AudioInput.phone,
                                  child: Text('Telefon')),
                              DropdownMenuItem(
                                  value: AudioInput.headset,
                                  child: Text('Headset')),
                            ],
                            onChanged: (value) {
                              if (value != null) _snailAudio.setInput(value);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                        'Audio-Geräte können während der Session gewechselt werden.',
                        style: Theme.of(context).textTheme.bodySmall),

                    if (_openAi != null) ...[
                      const SizedBox(height: 16),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Live-Transkript',
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 4),
                              Text(_openAi!.inputTranscript.isEmpty
                                  ? 'Quelle wird erkannt …'
                                  : _openAi!.inputTranscript),
                              const Divider(),
                              Text(_openAi!.outputTranscript.isEmpty
                                  ? 'Übersetzung wird erzeugt …'
                                  : _openAi!.outputTranscript),
                              const SizedBox(height: 4),
                              Text('Realtime: ${_openAi!.state}',
                                  style:
                                      Theme.of(context).textTheme.labelSmall),
                              if (_openAi!.lastError?.trim().isNotEmpty ==
                                  true) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Verbindungsdetail: ${_openAi!.lastError}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      // ── Latency panel ──
                      const SizedBox(height: 12),
                      ListenableBuilder(
                        listenable: _openAi!,
                        builder: (context, _) =>
                            _LatencyPanel(service: _openAi!),
                      ),
                    ],

                    // Show room code + QR while waiting (host only)
                    if (isHost &&
                        session != null &&
                        !audio.isPeerConnected) ...[
                      const SizedBox(height: 32),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: QrImageView(
                          // Keep the session QR deliberately short. The old
                          // payload appended a UUID and made the 180px code
                          // unnecessarily dense, which caused character
                          // substitutions on phone cameras.
                          data: session.roomId,
                          version: QrVersions.auto,
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                          size: 180,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Code: ${session.roomId}',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontFamily: 'monospace',
                                  letterSpacing: 2,
                                ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Lass deinen Gesprächspartner scannen'),
                    ],

                    SizedBox(height: compact ? 20 : 48),

                    // Mute button
                    IconButton.filled(
                      onPressed: () async {
                        audio.toggleMute();
                        if (audio.isMuted) await _snailAudio.stopPlayback();
                      },
                      icon: Icon(audio.isMuted ? Icons.mic_off : Icons.mic,
                          size: 32),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(80, 80),
                        backgroundColor: audio.isMuted
                            ? Colors.red
                            : Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // ── Audio level meter ──
                    ValueListenableBuilder<double>(
                      valueListenable: _micLevel,
                      builder: (context, level, _) => _LevelMeter(level: level),
                    ),
                    const SizedBox(height: 8),
                    Text(audio.isMuted ? 'Stumm' : 'Aktiv'),

                    SizedBox(height: compact ? 20 : 48),

                    // End session
                    OutlinedButton.icon(
                      onPressed: () => _confirmEndSession(context),
                      icon: const Icon(Icons.call_end, color: Colors.red),
                      label: const Text('Session beenden'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        minimumSize: const Size(200, 48),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact latency display showing input, output, and total round-trip time.
class _LatencyPanel extends StatelessWidget {
  const _LatencyPanel({required this.service});

  final OpenAiRealtimeService service;

  String _fmt(Duration? d) {
    if (d == null) return '—';
    final ms = d.inMilliseconds;
    if (ms < 1000) return '$ms ms';
    return '${(ms / 1000).toStringAsFixed(1)} s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tfa = service.timeToFirstAudio;
    final tft = service.timeToFirstTranscript;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.speed_rounded, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _LatencyChip(
                  label: 'Input',
                  value: _fmt(tfa),
                  icon: Icons.mic_rounded,
                  colors: colors,
                ),
                _LatencyChip(
                  label: 'Output',
                  value: _fmt(tft),
                  icon: Icons.headphones_rounded,
                  colors: colors,
                ),
                _LatencyChip(
                  label: 'Gesamt',
                  value: tfa != null && tft != null
                      ? _fmt(Duration(
                          milliseconds:
                              tfa.inMilliseconds + tft.inMilliseconds))
                      : '—',
                  icon: Icons.timer_rounded,
                  colors: colors,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LatencyChip extends StatelessWidget {
  const _LatencyChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.colors,
  });

  final String label;
  final String value;
  final IconData icon;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            color: colors.onSurface,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: colors.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }
}

/// Compact audio level meter showing microphone input level.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Map RMS level to a color: green → yellow → red
    final color = level < 0.3
        ? Colors.green
        : level < 0.7
            ? Colors.orange
            : colors.error;

    return SizedBox(
      width: 120,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            // Background
            Container(
              color: colors.onSurface.withValues(alpha: 0.1),
            ),
            // Active level
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: level.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
