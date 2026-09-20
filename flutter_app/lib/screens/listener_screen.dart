import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/translation_languages.dart';
import '../services/audio_service.dart';
import '../services/session_service.dart';
import '../services/tts_queue_policy.dart';
import '../services/user_identity_service.dart';

/// One subtitle line as shown to a listener.
class _SubtitleLine {
  const _SubtitleLine({
    required this.id,
    required this.text,
    required this.sourceLang,
    required this.targetLang,
    required this.timestamp,
  });

  final String id;
  final String text;
  final String sourceLang;
  final String targetLang;
  final int timestamp;
}

/// Listener side of guide mode: a pure display.
///
/// No provider key, no capture, no translation — the guide's device sends
/// every language and this screen filters to the one the listener picked.
/// Speech output is local (`flutter_tts`), so it works offline and costs
/// nothing.
class ListenerScreen extends StatefulWidget {
  const ListenerScreen({super.key});

  @override
  State<ListenerScreen> createState() => _ListenerScreenState();
}

class _ListenerScreenState extends State<ListenerScreen> {
  final _scrollController = ScrollController();
  final _questionController = TextEditingController();
  final _tts = FlutterTts();
  late final TtsQueuePolicy _ttsPolicy = TtsQueuePolicy(
    speak: _speak,
    stop: () async {
      try {
        await _tts.stop();
      } catch (_) {
        // The engine may be absent; subtitles remain the source of truth.
      }
    },
  );
  final List<_SubtitleLine> _lines = <_SubtitleLine>[];
  String? _language;
  bool _ttsEnabled = true;
  bool _ttsAvailable = true;
  bool _guideConnected = true;
  int _lastLineCount = 0;
  AudioService? _relay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _questionController.dispose();
    _tts.stop();
    final relay = _relay;
    if (relay != null) {
      relay.onSubtitle = null;
      relay.onKicked = null;
      // Deferred: disconnect() notifies its listeners, and notifying while
      // the framework is disposing this widget trips
      // "setState() called when widget tree was locked".
      scheduleMicrotask(relay.disconnect);
    }
    super.dispose();
  }

  Future<void> _connect() async {
    final sessionService = context.read<SessionService>();
    final session = sessionService.currentSession;
    if (session == null) return;
    // Default to the device language when the guide offers it, otherwise the
    // first offered language — a listener should never land on a language the
    // room does not serve.
    final offered = session.listenerLanguages;
    final deviceLanguage = sessionService.myLanguage;
    setState(() {
      _language = offered.contains(deviceLanguage)
          ? deviceLanguage
          : (offered.isNotEmpty ? offered.first : deviceLanguage);
    });

    final relay = context.read<AudioService>();
    _relay = relay;
    // Sent as an upgrade header so the worker's rate limit counts per device,
    // not per IP — a tour group on one wifi must not share a bucket.
    relay.localIdentityId =
        context.read<UserIdentityService>().identity?.userId;
    relay.onSubtitle = _onSubtitle;
    relay.onKicked = _onKicked;
    await relay.connect(session);
    if (!mounted) return;
    setState(() => _guideConnected = relay.isPeerConnected || true);
    await _configureTts();
  }

  /// The guide removed this device. Leave the screen instead of sitting on a
  /// connection that will never deliver another subtitle.
  void _onKicked() {
    if (!mounted) return;
    // Capture the messenger before the teardown: it lives above this route,
    // so the notice survives the pop. Showing it first would interleave a
    // setState with the disconnect's notifyListeners in the same frame.
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    _leave();
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.listenerRemovedByGuide)),
    );
  }

  void _leave() {
    final relay = _relay;
    _tts.stop();
    relay?.onSubtitle = null;
    relay?.onKicked = null;
    relay?.disconnect();
    context.read<SessionService>().endSession();
    Navigator.pop(context);
  }

  /// Sends the typed question to the guide. The relay routes a listener's
  /// chat message to the host only, so other listeners never see it.
  void _sendQuestion() {
    final text = _questionController.text.trim();
    if (text.isEmpty) return;
    final relay = _relay;
    if (relay == null) return;
    relay.sendChat(
      text,
      sourceLang: _language ?? 'en',
      targetLang: 'en',
    );
    _questionController.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).listenerQuestionSent)),
    );
  }

  /// A missing language pack must degrade silently to subtitles-only: the
  /// listener still reads everything, and a dialog would be noise.
  Future<void> _configureTts() async {
    try {
      final available = await _tts.isLanguageAvailable(_language ?? 'en');
      if (!mounted) return;
      setState(() => _ttsAvailable = available == true);
      if (available == true) {
        await _tts.setLanguage(_language ?? 'en');
        await _tts.awaitSpeakCompletion(false);
      }
    } catch (_) {
      if (mounted) setState(() => _ttsAvailable = false);
    }
  }

  void _onSubtitle(Map<String, dynamic> subtitle) {
    if (!mounted) return;
    final targetLang = subtitle['targetLang'] as String? ?? '';
    final text = (subtitle['text'] as String? ?? '').trim();
    if (text.isEmpty) return;
    final line = _SubtitleLine(
      id: subtitle['messageId'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      text: text,
      sourceLang: subtitle['sourceLang'] as String? ?? '',
      targetLang: targetLang,
      timestamp: subtitle['timestamp'] as int? ??
          DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _lines.add(line));
    _speakIfRelevant(line);
  }

  /// Only complete sentences are spoken, and the queue is dropped when it
  /// falls behind — otherwise the voice reads a transcript that is already
  /// twenty seconds old while the speaker has moved on.
  void _speakIfRelevant(_SubtitleLine line) {
    if (line.targetLang != _language) return;
    unawaited(_ttsPolicy.offer(line.text, enabled: _ttsEnabled && _ttsAvailable));
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {
      // Speech is best-effort; subtitles remain the source of truth.
    }
  }
  void _onLanguageChanged(String? language) {
    if (language == null || language == _language) return;
    setState(() => _language = language);
    unawaited(_configureTts());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionService>().currentSession;
    final offered = session?.listenerLanguages ?? const <String>[];
    final visible = _lines
        .where((line) => line.targetLang == _language)
        .toList(growable: false);

    // Follow the newest line: a bottom-appending list would otherwise open on
    // the oldest subtitle and never move.
    if (visible.length != _lastLineCount) {
      _lastLineCount = visible.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.listenerTitle),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: l10n.commonCancel,
            onPressed: _leave,
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _language,
                      decoration: InputDecoration(
                        labelText: l10n.listenerYourLanguage,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        isDense: true,
                      ),
                      items: [
                        for (final code in offered)
                          DropdownMenuItem(
                              value: code, child: Text(languageLabel(code))),
                      ],
                      onChanged: _onLanguageChanged,
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: l10n.listenerTtsToggle,
                    onPressed: _ttsAvailable
                        ? () => setState(() => _ttsEnabled = !_ttsEnabled)
                        : null,
                    icon: Icon(_ttsEnabled && _ttsAvailable
                        ? Icons.volume_up_rounded
                        : Icons.volume_off_rounded),
                  ),
                ],
              ),
            ),
            if (!_ttsAvailable)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(l10n.listenerTtsUnavailable,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6))),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _guideConnected
                        ? Icons.record_voice_over_rounded
                        : Icons.wifi_off_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _guideConnected
                          ? l10n.listenerGuideSpeaking
                          : l10n.listenerGuideGone,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        l10n.listenerWaiting,
                        style: TextStyle(
                            fontSize: 15,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6)),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final line = visible[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(
                            line.text,
                            style: const TextStyle(
                                fontSize: 22, height: 1.3),
                          ),
                        );
                      },
                    ),
            ),
            // Questions travel over the existing chat channel: the relay
            // routes a listener's chat to the host only.
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _questionController,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendQuestion(),
                        decoration: InputDecoration(
                          hintText: l10n.listenerAskQuestion,
                          isDense: true,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: l10n.listenerAskQuestion,
                      onPressed: _sendQuestion,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
