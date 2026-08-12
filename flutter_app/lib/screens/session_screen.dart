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
import '../services/p2p_audio_service.dart';
import '../services/user_identity_service.dart';
import '../services/transcript_history.dart';
import '../services/audio_policy.dart';
import '../services/audio_processor.dart';
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

class _SessionScreenState extends State<SessionScreen> {
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
  final _p2p = P2pAudioService();
  VoidCallback? _geminiListener;
  VoidCallback? _openAiListener;
  VoidCallback? _guestFallbackOpenAiListener;
  bool _openAiPlaybackRunning = false;
  bool _fallbackPlaybackRunning = false;
  final List<_SessionPlaybackChunk> _playbackQueue =
      <_SessionPlaybackChunk>[];
  bool _playbackDraining = false;
  static const _maxPlaybackQueue = 24;
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
  };

  Future<void> _showLanguagePicker() async {
    final sessionService = context.read<SessionService>();
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Meine Sprache'),
              subtitle: Text('Gilt fuer die naechste neue Session.'),
            ),
            for (final entry in _languageLabels.entries)
              ListTile(
                leading: Icon(entry.key == sessionService.myLanguage
                    ? Icons.check_circle
                    : Icons.language),
                title: Text(entry.value),
                trailing: Text(entry.key.toUpperCase()),
                onTap: () => Navigator.pop(sheetContext, entry.key),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await sessionService.setMyLanguage(selected);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Sprache gespeichert. Sie wird bei der naechsten Session verwendet.'),
      ));
    }
  }

  bool _isConnectionActive(int generation) =>
      mounted && generation == _connectionGeneration;
  @override
  void initState() {
    super.initState();
    _audioService = context.read<AudioService>();
    _sessionService = context.read<SessionService>();
    _transcriptHistory = context.read<TranscriptHistory>();
    _audioPolicy = context.read<AudioPolicy>();
    // Keep the session alive while the user is actively translating. This is
    // intentionally scoped to the session route and released on exit.
    WakelockPlus.enable();
    unawaited(_connect(_connectionGeneration));
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
      _p2p.onAudio = (bytes, sampleRate) =>
      _enqueueSessionPlayback(bytes, sampleRate);
      _p2p.onChat = relayAudio.receiveP2pData;
      relayAudio.isP2pConnected = () => _p2p.isConnected;
      relayAudio.onP2pChatSend = _p2p.sendChat;
      relayAudio.onP2pStickerSend = _p2p.sendData;
      relayAudio.onSignal = (type, signal) => _p2p.acceptSignal(type, signal);
      relayAudio.onPcmAudio = (bytes, sampleRate) {
        // Relay PCM is a fallback while ICE is negotiating.
        if (!_p2p.isConnected) {
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
        final echoGuardEnabled = _audioPolicy.profile == AudioPolicyProfile.headset
            ? false
            : _audioPolicy.forceEchoGuard || _snailAudio.echoGuardEnabled;
        final provider = providerConfig.config;
        // OpenAI may use a Worker-minted short-lived secret when no local
        // BYOK key is configured. If neither exists, deliberately fall back
        // to the session owner's provider instead of failing the guest.
        String? openAiCredential;
        // `handleJoinRoom` already mirrors source/target for the guest. Both
        // devices therefore translate their own microphone into targetLang.
        final targetLanguage = session.targetLang;
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
              _micLevel.value = AudioProcessor.computeLevel(chunk);
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
                      backgroundColor:
                          Theme.of(context).colorScheme.error,
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
                if (!AudioProcessor.detectSilence(chunk)) {
                  _openAi!.sendPcm16(chunk);
                }
              }
            });
          } else {
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
    _connectionGeneration++;
    WakelockPlus.disable();
    unawaited(_snailAudio.stopSessionKeepAlive());
    _audioSubscription?.cancel();
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
    _guestFallbackOpenAi?.disconnect();
    _audioService.onPcmAudio = null;
    _audioService.onFallbackPcmAudio = null;
    _audioService.onSignal = null;
    _audioService.onAuthenticated = null;
    _p2p.dispose();
    _playbackQueue.clear();
    _snailAudio.dispose();
    _micLevel.dispose();
    _audioService.disconnect();
    super.dispose();
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
    _drainSessionPlayback();
  }

  Future<void> _drainSessionPlayback() async {
    if (_playbackDraining) return;
    _playbackDraining = true;
    try {
      while (mounted && _playbackQueue.isNotEmpty) {
        final chunk = _playbackQueue.removeAt(0);
        await _snailAudio.playPcm16(chunk.bytes,
            sampleRate: chunk.sampleRate);
      }
    } finally {
      _playbackDraining = false;
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

                    TextButton.icon(
                      onPressed: _showLanguagePicker,
                      icon: const Icon(Icons.language),
                      label: Text(
                        'Meine Sprache: ${session?.sourceLang.toUpperCase() ?? 'DE'}',
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        textStyle: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),

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
                      onPressed: () => audio.toggleMute(),
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
                      builder: (context, level, _) =>
                          _LevelMeter(level: level),
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
