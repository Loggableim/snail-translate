import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/translation_languages.dart';
import '../services/audio_service.dart';
import '../services/session_service.dart';

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
  final _tts = FlutterTts();
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
    _tts.stop();
    final relay = _relay;
    if (relay != null) {
      relay.onSubtitle = null;
      relay.disconnect();
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
    relay.onSubtitle = _onSubtitle;
    await relay.connect(session);
    if (!mounted) return;
    setState(() => _guideConnected = relay.isPeerConnected || true);
    await _configureTts();
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
    if (!_ttsEnabled || !_ttsAvailable) return;
    if (line.targetLang != _language) return;
    if (!_isCompleteSentence(line.text)) return;
    unawaited(_speak(line.text));
  }

  static bool _isCompleteSentence(String text) {
    final trimmed = text.trim();
    if (trimmed.length < 2) return false;
    return RegExp(r'[.!?。！？…]$').hasMatch(trimmed);
  }

  Future<void> _speak(String text) async {
    try {
      // Drop anything still queued: late audio is worse than none.
      await _tts.stop();
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
        final relay = _relay;
        _tts.stop();
        relay?.disconnect();
        if (!mounted) return;
        context.read<SessionService>().endSession();
        Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.listenerTitle),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: l10n.commonCancel,
            onPressed: () {
              final relay = _relay;
              _tts.stop();
              relay?.disconnect();
              context.read<SessionService>().endSession();
              Navigator.pop(context);
            },
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
          ],
        ),
      ),
    );
  }
}
