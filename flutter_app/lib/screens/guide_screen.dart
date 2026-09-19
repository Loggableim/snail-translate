import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/provider_config.dart';
import '../models/translation_languages.dart';
import '../services/audio_service.dart';
import '../services/fish_audio_asr_service.dart';
import '../services/openai_realtime_service.dart';
import '../services/provider_config_service.dart';
import '../services/session_service.dart';
import '../services/snail_audio.dart';
import '../services/speech_turn_buffer.dart';
import '../services/translation_service.dart';

/// Guide mode: one speaker, N listeners.
///
/// The guide's device does the work — capture, ASR and one translation per
/// offered listener language — and publishes the result as `subtitle`
/// messages. Listeners are pure displays: they need no provider key and
/// receive every language, filtering locally.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _audio = SnailAudio();
  final _openAi = OpenAiRealtimeService();
  final _fishAsr = FishAudioAsrService();
  final _translator = TranslationService();

  final Set<String> _listenerLanguages = <String>{};
  bool _running = false;
  bool _starting = false;
  String? _error;
  int _listenerCount = 0;
  List<String> _listenerIds = const <String>[];
  String _sourceText = '';
  final List<String> _questions = <String>[];
  /// Every published line, kept for the transcript export.
  final List<String> _transcript = <String>[];

  // Fish pipeline state (mirrors the standalone screen's turn handling).
  SpeechTurnBuffer? _fishTurns;
  bool _fishBusy = false;
  Timer? _fishProcessTimer;
  Timer? _uiRefreshTimer;
  StreamSubscription<Map<String, dynamic>>? _captureSubscription;
  AudioService? _relay;

  @override
  void dispose() {
    _captureSubscription?.cancel();
    _fishProcessTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _audio.stopStandaloneCapture();
    unawaited(_audio.dispose());
    _openAi.dispose();
    super.dispose();
  }

  ProviderConfig get _config => context.read<ProviderConfigService>().config;

  /// Gemini cannot translate text (`gemini_chat_translation_not_supported`),
  /// so a guide session on it would transcribe and then fail on every turn.
  bool get _providerSupported =>
      _config.provider == TranslationProvider.fishAudio ||
      _config.provider == TranslationProvider.openAi;

  Future<void> _start() async {
    if (_listenerLanguages.isEmpty) {
      setState(() => _error = AppLocalizations.of(context).guideNoLanguages);
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });

    final sessionService = context.read<SessionService>();
    final session = await sessionService.createGuideRoom(
      listenerLanguages: _listenerLanguages.toList(growable: false),
    );
    if (!mounted) return;
    if (session == null) {
      setState(() {
        _starting = false;
        _error = sessionService.localizedError(AppLocalizations.of(context));
      });
      return;
    }

    final relay = context.read<AudioService>();
    _relay = relay;
    relay.onSubtitle = null;
    relay.onListenerCountChanged = (count) {
      if (mounted) setState(() => _listenerCount = count);
    };
    relay.onListenerListChanged = (ids) {
      if (mounted) setState(() => _listenerIds = ids);
    };
    final connected = await relay.connect(session);
    if (!mounted) return;
    if (!connected) {
      setState(() {
        _starting = false;
        _error = AppLocalizations.of(context).guideConnectionFailed;
      });
      return;
    }

    final config = _config;
    final captureStarted = await _audio.startStandaloneCapture(
      sampleRate: 16000,
      aecEnabled: true,
      noiseSuppressionEnabled: true,
    );
    if (!mounted) return;
    if (!captureStarted) {
      relay.disconnect();
      setState(() {
        _starting = false;
        _error = AppLocalizations.of(context).guideCaptureFailed;
      });
      return;
    }

    if (config.provider == TranslationProvider.fishAudio) {
      _fishTurns = SpeechTurnBuffer(
        gateThreshold: 0.012,
        maxTurn: const Duration(seconds: 4),
      );
      _fishProcessTimer = Timer.periodic(const Duration(milliseconds: 250),
          (_) => _processFishTurn(config));
    } else {
      await _openAi.connect(
        apiKey: config.apiKey,
        // The realtime endpoint always needs a target; the guide translates
        // per listener language afterwards, so the first offered language is
        // only used to satisfy the provider contract.
        targetLanguage: _listenerLanguages.first,
      );
      if (!mounted) return;
    }

    _captureSubscription = _audio.standaloneStream?.listen((frame) {
      if (!mounted || !_running) return;
      final bytes = frame['bytes'] as Uint8List;
      final rate = frame['sampleRate'] as int? ?? 16000;
      if (config.provider == TranslationProvider.fishAudio) {
        _fishTurns?.add(bytes, DateTime.now());
      } else {
        _openAi.sendPcm16(bytes, inputSampleRate: rate);
      }
    });

    _uiRefreshTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_running) return;
      if (config.provider == TranslationProvider.openAi) {
        _drainOpenAiTurns(config);
      }
    });

    setState(() {
      _running = true;
      _starting = false;
    });
  }

  /// OpenAI path: the realtime endpoint reports completed input turns; the
  /// output side (audio/translation) is deliberately ignored — the guide
  /// translates the source text itself, once per offered language.
  void _drainOpenAiTurns(ProviderConfig config) {
    for (final turn in _openAi.takeCompletedTurns()) {
      final source = turn.sourceText.trim();
      if (source.isEmpty) continue;
      unawaited(_publish(source, config));
    }
  }

  Future<void> _processFishTurn(ProviderConfig config) async {
    final turns = _fishTurns;
    if (turns == null || _fishBusy) return;
    if (!turns.isTurnComplete(DateTime.now())) return;
    final pcm = turns.takeTurn();
    if (pcm == null) return;
    _fishBusy = true;
    try {
      final transcript = await _fishAsr.transcribe(
        apiKey: config.apiKey,
        pcm16: pcm,
        sampleRate: 16000,
        language: null,
      );
      final source = transcript.trim();
      if (source.isEmpty) return;
      // Fish ASR invents whole sentences on echo, noise or silence. A
      // wrong-language invention would be translated into every listener
      // language and shown to the whole audience.
      if (FishAudioAsrService.isImplausibleTranscript(
          source, _guideLanguage)) {
        return;
      }
      await _publish(source, config);
    } catch (_) {
      // A single failed turn must not tear down the session.
    } finally {
      _fishBusy = false;
    }
  }

  String get _guideLanguage =>
      context.read<SessionService>().currentSession?.sourceLang ?? 'de';

  /// Translates one source line into every offered language and publishes
  /// each result. The guide's own language is skipped — listeners who speak
  /// it read the original.
  Future<void> _publish(String source, ProviderConfig config) async {
    final relay = _relay;
    if (relay == null) return;
    final sourceLang = _guideLanguage;
    if (mounted) {
      setState(() {
        _sourceText = source;
        _transcript.add(source);
      });
    }

    final targets = _listenerLanguages
        .where((lang) => lang != sourceLang)
        .toList(growable: false);
    if (targets.isEmpty) return;

    final results = await Future.wait(targets.map((target) async {
      final result = await _translator.translate(
        text: source,
        sourceLang: sourceLang,
        targetLang: target,
        config: config,
      );
      return MapEntry(target, result);
    }));

    for (final entry in results) {
      final result = entry.value;
      if (!result.translated) continue;
      relay.sendSubtitle(
        text: result.text,
        sourceLang: sourceLang,
        targetLang: entry.key,
      );
    }
  }

  Future<void> _stop() async {
    _captureSubscription?.cancel();
    _captureSubscription = null;
    _fishProcessTimer?.cancel();
    _fishProcessTimer = null;
    _uiRefreshTimer?.cancel();
    _uiRefreshTimer = null;
    await _audio.stopStandaloneCapture();
    await _openAi.disconnect();
    final relay = _relay;
    if (relay != null) {
      relay.onListenerCountChanged = null;
      relay.onListenerListChanged = null;
      relay.disconnect();
    }
    if (!mounted) return;
    context.read<SessionService>().endSession();
    setState(() {
      _running = false;
      _listenerCount = 0;
      _listenerIds = const <String>[];
      _sourceText = '';
      _questions.clear();
    });
  }

  /// Copies the collected source lines to the clipboard. The relay already
  /// keeps the full transcript for late joiners; this is the guide's own
  /// copy for notes and reports.
  Future<void> _exportTranscript() async {
    final l10n = AppLocalizations.of(context);
    if (_transcript.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _transcript.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.guideTranscriptCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionService>().currentSession;
    final relay = context.watch<AudioService>();
    // Incoming listener questions arrive through the shared chat service.
    final messages = relay.messages;
    final questions = messages
        .where((message) => !message.outgoing)
        .map((message) => message.text)
        .toList(growable: false);

    return PopScope(
      // System-back must run the same teardown as the explicit stop button;
      // dispose() alone would leave the relay session and capture alive.
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _stop();
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.guideTitle),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: l10n.commonCancel,
            onPressed: () async {
              if (_running) {
                await _stop();
              }
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ),
        body: _running && session != null
            ? _buildRunning(context, l10n, session.roomId, questions)
            : _buildSetup(context, l10n),
      ),
    );
  }

  Widget _buildSetup(BuildContext context, AppLocalizations l10n) {
    final config = context.watch<ProviderConfigService>().config;
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(l10n.guideHeadline,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(l10n.guideExplanation,
            style: TextStyle(
                fontSize: 14, color: colors.onSurface.withValues(alpha: 0.7))),
        const SizedBox(height: 24),
        Text(l10n.guideListenerLanguages,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final language in translationLanguages)
              FilterChip(
                label: Text(language.native),
                selected: _listenerLanguages.contains(language.code),
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _listenerLanguages.add(language.code);
                    } else {
                      _listenerLanguages.remove(language.code);
                    }
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 24),
        if (!_providerSupported)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              Icon(Icons.info_outline_rounded, size: 20, color: colors.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(l10n.guideProviderUnsupported(
                    config.provider.displayName),
                    style: const TextStyle(fontSize: 13)),
              ),
            ]),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: TextStyle(color: colors.error, fontSize: 13),
              textAlign: TextAlign.center),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _starting || !_providerSupported ? null : _start,
            icon: _starting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.campaign_rounded),
            label: Text(_starting ? l10n.guideStarting : l10n.guideStart,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _buildRunning(BuildContext context, AppLocalizations l10n,
      String roomId, List<String> questions) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(data: roomId, size: 180),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(l10n.sessionRoomCode(roomId),
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(l10n.guideListenerCount(_listenerCount),
              style: TextStyle(
                  fontSize: 14,
                  color: colors.onSurface.withValues(alpha: 0.7))),
        ),
        // The roster is only useful when someone can be removed from it.
        if (_listenerIds.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final listenerId in _listenerIds)
                InputChip(
                  label: Text(
                    listenerId.length > 10
                        ? '${listenerId.substring(0, 8)}…'
                        : listenerId,
                    style: const TextStyle(fontSize: 12),
                  ),
                  deleteIcon: const Icon(Icons.person_remove_rounded, size: 16),
                  deleteButtonTooltipMessage: l10n.guideKickListener,
                  onDeleted: () =>
                      context.read<AudioService>().sendListenerKick(listenerId),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Text(l10n.guideYouSaid,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            _sourceText.isEmpty ? l10n.guideWaitingForSpeech : _sourceText,
            style: const TextStyle(fontSize: 18),
          ),
        ),
        const SizedBox(height: 20),
        Text(l10n.guideQuestions,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (questions.isEmpty)
          Text(l10n.guideNoQuestions,
              style: TextStyle(
                  fontSize: 13,
                  color: colors.onSurface.withValues(alpha: 0.6)))
        else
          for (final question in questions)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(question, style: const TextStyle(fontSize: 14)),
              ),
            ),
        const SizedBox(height: 24),
        if (_transcript.isNotEmpty) ...[
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _exportTranscript,
              icon: const Icon(Icons.copy_all_rounded),
              label: Text(l10n.guideExportTranscript),
            ),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _stop,
            icon: const Icon(Icons.stop_rounded),
            label: Text(l10n.guideStop),
          ),
        ),
      ],
    );
  }
}
