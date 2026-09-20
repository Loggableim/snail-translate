import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../models/message_status.dart';
import '../services/audio_service.dart';
import '../services/session_service.dart';
import '../services/provider_config_service.dart';
import '../services/snail_audio.dart';
import '../services/translation_service.dart';
import '../services/voice_recorder.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _translator = TranslationService();
  final _scrollController = ScrollController();
  final _audio = SnailAudio();
  late final VoiceRecorder _recorder = VoiceRecorder(audio: _audio);
  bool _translating = false;
  bool _recording = false;
  String? _playingMessageId;
  final Set<String> _translatedIncoming = {};
  // Incoming messages translated locally for display only. Keyed by message
  // id; rendered as an annotation under the original bubble.
  final Map<String, String> _incomingTranslations = {};
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    // New messages append at the bottom of the list; keep the viewport on the
    // newest bubble whenever the message count grows.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    // A recording that hits the duration limit is sent automatically: the
    // relay would reject anything longer, so stopping is not optional.
    unawaited(_recorder.onLimitReached.then((_) {
      if (mounted && _recording) unawaited(_stopAndSendVoice());
    }));
  }

  /// Plays a voice note. PCM16 at the note's own sample rate, so no resampling
  /// is needed on the way out.
  Future<void> _playVoice(ChatMessage message) async {
    if (_playingMessageId != null) return;
    setState(() => _playingMessageId = message.id);
    try {
      final bytes = base64Decode(message.audioData);
      await _audio.playPcm16(Uint8List.fromList(bytes),
          sampleRate: message.sampleRate);
      // The native player returns immediately; hold the indicator for the
      // note's duration so the UI reflects what is audible.
      await Future<void>.delayed(
          Duration(milliseconds: message.durationMs.clamp(200, 30000)));
    } catch (_) {
      // A corrupt payload must not break the chat.
    } finally {
      if (mounted) setState(() => _playingMessageId = null);
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopAndSendVoice();
      return;
    }
    final started = await _recorder.start();
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).voiceMicUnavailable)));
      return;
    }
    setState(() => _recording = true);
  }

  Future<void> _stopAndSendVoice() async {
    final note = await _recorder.stop();
    if (!mounted) return;
    setState(() => _recording = false);
    if (note == null) return;
    final session = context.read<SessionService>();
    await context.read<AudioService>().chat.sendVoice(
          audioData: note.audioData,
          durationMs: note.durationMs,
          sampleRate: note.sampleRate,
          sourceLang: session.myLanguage,
          targetLang: session.currentSession?.targetLang ??
              session.targetLanguage,
        );
  }

  Future<void> _cancelRecording() async {
    await _recorder.cancel();
    if (mounted) setState(() => _recording = false);
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final audio = context.watch<AudioService>();
    final session = context.watch<SessionService>();
    if (!session.isInSession) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.chatMessengerTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.forum_outlined, size: 72),
              const SizedBox(height: 16),
              Text(l10n.chatNeedsSessionHint, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/qr-host'),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.chatStartChatSession)),
              TextButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/join'),
                  icon: const Icon(Icons.login),
                  label: Text(l10n.chatJoinSession)),
            ]),
          ),
        ),
      );
    }
    if (session.currentSession?.role == 'host') {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _translateIncoming(audio, session));
    }
    // Keep the newest message visible as the conversation grows.
    final messageCount = audio.messages.length;
    if (messageCount != _lastMessageCount) {
      _lastMessageCount = messageCount;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Snail Chat',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              Text(l10n.chatLiveTranslationActive,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.normal))
            ]),
        actions: [
          // The safety number is only meaningful once a peer key exists, so
          // the entry point appears with the conversation.
          if (audio.keyFingerprint != null)
            IconButton(
                tooltip: l10n.fingerprintTitle,
                icon: const Icon(Icons.verified_user_outlined),
                onPressed: () =>
                    Navigator.pushNamed(context, '/fingerprint')),
          if (audio.pendingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                  child: Text(l10n.chatPendingCount(audio.pendingCount))),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: audio.messages.length,
              itemBuilder: (_, index) {
                final message = audio.messages[index];
                final bubbleColor = message.outgoing
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest;
                final textColor = message.outgoing
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface;
                final translation = !message.outgoing
                    ? _incomingTranslations[message.id]
                    : null;
                return Align(
                  alignment: message.outgoing
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .78),
                    margin:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    padding: const EdgeInsets.fromLTRB(14, 9, 10, 7),
                    decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(18),
                            topRight: const Radius.circular(18),
                            bottomLeft:
                                Radius.circular(message.outgoing ? 18 : 4),
                            bottomRight:
                                Radius.circular(message.outgoing ? 4 : 18))),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: message.outgoing
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                    child: message.isVoice
                                        // A voice note has no text: it renders
                                        // as a play control plus its length.
                                        ? _VoiceBubble(
                                            message: message,
                                            playing: _playingMessageId ==
                                                message.id,
                                            onPlay: () => _playVoice(message),
                                            textColor: textColor,
                                          )
                                        : Text(message.text,
                                            style: TextStyle(
                                                color: textColor,
                                                fontSize: 15))),
                                const SizedBox(width: 8),
                                Text(_time(message.timestamp),
                                    style: TextStyle(
                                        color: textColor.withAlpha(170),
                                        fontSize: 10)),
                                if (message.outgoing) ...[
                                  const SizedBox(width: 3),
                                  Icon(
                                    switch (message.status) {
                                      MessageStatus.queued => Icons.schedule,
                                      MessageStatus.delivered ||
                                      MessageStatus.read =>
                                        Icons.done_all,
                                      MessageStatus.sent => Icons.done,
                                    },
                                    size: 14,
                                    color: textColor.withAlpha(170),
                                  ),
                                ],
                              ]),
                          if (translation != null &&
                              translation.trim().isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(translation,
                                style: TextStyle(
                                    color: textColor.withAlpha(200),
                                    fontSize: 14,
                                    fontStyle: FontStyle.italic)),
                          ],
                        ]),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: _recording
                  ? _RecordingBar(
                      elapsed: _recorder.elapsed,
                      onCancel: _cancelRecording,
                      onSend: _stopAndSendVoice,
                    )
                  : Row(
                      children: [
                        Expanded(
                            child: TextField(
                                controller: _controller,
                                enabled: !_translating,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _send(audio, session))),
                        IconButton(
                            tooltip: l10n.voiceRecordTooltip,
                            icon: const Icon(Icons.mic_none),
                            onPressed:
                                _translating ? null : _toggleRecording),
                        IconButton(
                            tooltip: l10n.chatSendTooltip,
                            icon: _translating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.send),
                            onPressed: _translating
                                ? null
                                : () => _send(audio, session)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  Future<void> _translateIncoming(
      AudioService audio, SessionService session) async {
    for (final message in audio.messages) {
      if (message.id.isEmpty || _translatedIncoming.contains(message.id)) {
        continue;
      }
      _translatedIncoming.add(message.id);
      try {
        final provider = context.read<ProviderConfigService>().config;
        final result = await _translator.translate(
            text: message.text,
            sourceLang: message.sourceLang,
            targetLang: message.targetLang,
            config: provider);
        if (!mounted) return;
        if (!result.translated) {
          // Chat keeps the original readable on screen when translation is
          // unavailable, unlike the audio path where TTS would speak it aloud.
          _translatedIncoming.remove(message.id);
          continue;
        }
        // Show the translation as an annotation on the original bubble
        // instead of sending it back over the wire: echoing it as an
        // outgoing message made the host's own chat fill with bubbles it
        // never typed.
        setState(() => _incomingTranslations[message.id] = result.text);
      } catch (_) {
        _translatedIncoming.remove(message.id);
      }
    }
  }

  Future<void> _send(AudioService audio, SessionService session) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);
    try {
      var outgoing = text;
      final provider = context.read<ProviderConfigService>().config;
      final target =
          session.currentSession?.targetLang ?? session.targetLanguage;
      final canTranslateLocally = provider.provider.name == 'ollama' ||
          provider.apiKey.trim().isNotEmpty;
      var alreadyTranslated = false;
      // Hosts use their configured provider. Guests use their own key when
      // present; without one, the host-side incoming-message fallback applies.
      if (canTranslateLocally) {
        final result = await _translator.translate(
            text: text,
            sourceLang: session.myLanguage,
            targetLang: target,
            config: provider);
        outgoing = result.text;
        // Only claim the message is translated when it actually was, so the
        // peer still applies its own fallback instead of trusting the tag.
        alreadyTranslated =
            result.translated && session.currentSession?.role == 'guest';
      }
      audio.sendChat(
        outgoing,
        sourceLang: session.myLanguage,
        targetLang: alreadyTranslated ? session.myLanguage : target,
      );
      _controller.clear();
    } catch (_) {
      // A failed translation must never swallow the message: Gemini chat
      // translation is unsupported and Ollama may simply be unreachable.
      // Send the original text so the peer-side fallback can still do its
      // job, and tell the user what happened.
      audio.sendChat(
        text,
        sourceLang: session.myLanguage,
        targetLang: session.currentSession?.targetLang ?? session.targetLanguage,
      );
      _controller.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)
                .chatTranslationFailed(
                    AppLocalizations.of(context).commonError))));
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    _audio.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

/// Play control for a voice note inside a chat bubble.
class _VoiceBubble extends StatelessWidget {
  const _VoiceBubble({
    required this.message,
    required this.playing,
    required this.onPlay,
    required this.textColor,
  });

  final ChatMessage message;
  final bool playing;
  final VoidCallback onPlay;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final seconds = (message.durationMs / 1000).round();
    final label = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        onPressed: playing ? null : onPlay,
        iconSize: 26,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        icon: Icon(
          playing ? Icons.graphic_eq : Icons.play_arrow_rounded,
          color: textColor,
        ),
      ),
      const SizedBox(width: 4),
      Icon(Icons.mic, size: 14, color: textColor.withAlpha(170)),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              color: textColor.withAlpha(200),
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

/// Replaces the composer while a recording is in progress.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.elapsed,
    required this.onCancel,
    required this.onSend,
  });

  final Duration elapsed;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final seconds = elapsed.inSeconds;
    final label = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Row(children: [
      IconButton(
          tooltip: l10n.commonCancel,
          icon: const Icon(Icons.delete_outline),
          onPressed: onCancel),
      const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 14),
      const SizedBox(width: 8),
      Expanded(
          child: Text(l10n.voiceRecordingLabel(label),
              style: const TextStyle(fontFeatures: [
                FontFeature.tabularFigures()
              ]))),
      IconButton(
          tooltip: l10n.chatSendTooltip,
          icon: const Icon(Icons.send),
          onPressed: onSend),
    ]);
  }
}
