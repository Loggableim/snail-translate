import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/message_status.dart';
import '../services/audio_service.dart';
import '../services/session_service.dart';
import '../services/provider_config_service.dart';
import '../services/translation_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _translator = TranslationService();
  bool _translating = false;
  final Set<String> _translatedIncoming = {};

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
                    child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                              child: Text(message.text,
                                  style: TextStyle(
                                      color: textColor, fontSize: 15))),
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
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                      child: TextField(
                          controller: _controller,
                          enabled: !_translating,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(audio, session))),
                  IconButton(
                      icon: _translating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send),
                      onPressed:
                          _translating ? null : () => _send(audio, session)),
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
        // Chat keeps the original readable on screen when translation is
        // unavailable, unlike the audio path where TTS would speak it aloud.
        audio.sendChat(result.text,
            sourceLang: message.sourceLang, targetLang: message.targetLang);
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
    _controller.dispose();
    super.dispose();
  }
}
