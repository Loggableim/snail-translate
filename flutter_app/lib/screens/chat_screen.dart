import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_service.dart';
import '../services/session_service.dart';
import '../models/sticker_message.dart';
import '../services/provider_config_service.dart';
import '../services/translation_service.dart';
import '../services/telegram_sticker_service.dart';

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
  final _telegram = TelegramStickerService();
  List<StickerMessage> _importedStickers = const [];

  @override
  Widget build(BuildContext context) {
    final audio = context.watch<AudioService>();
    final session = context.watch<SessionService>();
    if (!session.isInSession) {
      return Scaffold(
        appBar: AppBar(title: const Text('Snail Messenger')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.forum_outlined, size: 72),
              const SizedBox(height: 16),
              const Text(
                  'Für den Messenger zuerst eine Session öffnen oder beitreten.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/qr-host'),
                  icon: const Icon(Icons.add),
                  label: const Text('Chat-Session starten')),
              TextButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/join'),
                  icon: const Icon(Icons.login),
                  label: const Text('Session beitreten')),
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
        title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Snail Chat', style: TextStyle(fontWeight: FontWeight.w800)),
              Text('Live-Übersetzung aktiv',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal))
            ]),
        actions: [
          if (audio.pendingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: Text('${audio.pendingCount} ausstehend')),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: audio.messages.length + audio.stickers.length,
              itemBuilder: (_, index) {
                if (index >= audio.messages.length) {
                  final sticker = audio.stickers[index - audio.messages.length];
                  return Align(
                    alignment: sticker.outgoing
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: sticker.isAnimated || sticker.isVideo
                          ? Text(sticker.emoji,
                              style: const TextStyle(fontSize: 48))
                          : _stickerImage(sticker),
                    ),
                  );
                }
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
                            Icon(Icons.done_all,
                                size: 14, color: Colors.white70)
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
                  IconButton(
                      icon: const Icon(Icons.emoji_emotions_outlined),
                      onPressed: () => _sendSticker(audio)),
                  IconButton(
                      icon: const Icon(Icons.library_add_outlined),
                      tooltip: 'Telegram-Stickerpack importieren',
                      onPressed: _importTelegramPack),
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
        final translated = await _translator.translate(
            text: message.text,
            sourceLang: message.sourceLang,
            targetLang: message.targetLang,
            config: provider);
        audio.sendChat(translated,
            sourceLang: message.sourceLang, targetLang: message.targetLang);
      } catch (_) {
        _translatedIncoming.remove(message.id);
      }
    }
  }

  void _sendSticker(AudioService audio) {
    if (_importedStickers.isNotEmpty) {
      final sticker = _importedStickers.first;
      setState(
          () => _importedStickers = [..._importedStickers.skip(1), sticker]);
      audio.sendSticker(sticker);
      return;
    }
    // Sticker assets are provider-neutral. Telegram imports can populate the
    // same payload later; this button proves the transport contract now.
    audio.sendSticker(const StickerMessage(
      id: 'snail-demo-sticker',
      assetUrl:
          'https://cdn.jsdelivr.net/gh/twitter/twemoji/assets/72x72/1f604.png',
      emoji: '😄',
      packShortName: 'snail-demo',
      mimeType: 'image/png',
    ));
  }

  Widget _stickerImage(StickerMessage sticker) {
    if (sticker.assetUrl.startsWith('data:')) {
      final comma = sticker.assetUrl.indexOf(',');
      if (comma > 0) {
        try {
          return Image.memory(
              base64Decode(sticker.assetUrl.substring(comma + 1)),
              width: 96,
              height: 96,
              errorBuilder: (_, __, ___) =>
                  Text(sticker.emoji, style: const TextStyle(fontSize: 48)));
        } catch (_) {}
      }
    }
    return Image.network(sticker.assetUrl,
        width: 96,
        height: 96,
        errorBuilder: (_, __, ___) =>
            Text(sticker.emoji, style: const TextStyle(fontSize: 48)));
  }

  Future<void> _importTelegramPack() async {
    final link = TextEditingController();
    final token = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Telegram-Stickerpack'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: link,
              decoration: const InputDecoration(
                  labelText: 'Pack-Link (t.me/addstickers/...)')),
          TextField(
              controller: token,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Telegram-Bot-Token')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, [link.text, token.text]),
              child: const Text('Importieren')),
        ],
      ),
    );
    link.dispose();
    token.dispose();
    if (values == null || !mounted) return;
    try {
      final imported =
          await _telegram.importPack(botToken: values[1], packLink: values[0]);
      if (!mounted) return;
      setState(() => _importedStickers = imported);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${imported.length} Sticker importiert')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Telegram-Import fehlgeschlagen: $error')));
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
        outgoing = await _translator.translate(
            text: text,
            sourceLang: session.myLanguage,
            targetLang: target,
            config: provider);
        alreadyTranslated = session.currentSession?.role == 'guest';
      }
      audio.sendChat(
        outgoing,
        sourceLang: alreadyTranslated ? session.myLanguage : session.myLanguage,
        targetLang: alreadyTranslated ? session.myLanguage : target,
      );
      _controller.clear();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Übersetzung fehlgeschlagen: $error')));
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
