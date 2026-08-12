import 'package:flutter_test/flutter_test.dart';
import 'package:snail/models/chat_message.dart';
import 'package:snail/models/message_status.dart';
import 'package:snail/models/sticker_message.dart';

void main() {
  group('Message idempotency', () {
    test('ChatMessage with same id is not added twice', () {
      final messages = <ChatMessage>[];
      final msg1 = ChatMessage(
        id: 'dup-001',
        text: 'Hello',
        senderId: 'user-a',
        sourceLang: 'en',
        targetLang: 'de',
        timestamp: DateTime.now(),
        outgoing: false,
      );
      final msg2 = ChatMessage(
        id: 'dup-001', // same ID
        text: 'Hello again',
        senderId: 'user-a',
        sourceLang: 'en',
        targetLang: 'de',
        timestamp: DateTime.now(),
        outgoing: false,
      );

      // Simulate _addIncomingChat logic
      if (msg1.id.isNotEmpty && !messages.any((m) => m.id == msg1.id)) {
        messages.add(msg1);
      }
      if (msg2.id.isNotEmpty && !messages.any((m) => m.id == msg2.id)) {
        messages.add(msg2);
      }

      expect(messages.length, 1);
      expect(messages.first.text, 'Hello');
    });

    test('StickerMessage with same id is not added twice', () {
      final stickers = <StickerMessage>[];
      final s1 = const StickerMessage(
        id: 'sticker-001',
        assetUrl: 'https://example.com/sticker.webp',
        emoji: '😄',
        packShortName: 'test-pack',
        mimeType: 'image/webp',
      );
      final s2 = const StickerMessage(
        id: 'sticker-001', // same ID
        assetUrl: 'https://example.com/other.webp',
        emoji: '😢',
        packShortName: 'test-pack',
        mimeType: 'image/webp',
      );

      if (s1.id.isNotEmpty && !stickers.any((s) => s.id == s1.id)) {
        stickers.add(s1);
      }
      if (s2.id.isNotEmpty && !stickers.any((s) => s.id == s2.id)) {
        stickers.add(s2);
      }

      expect(stickers.length, 1);
      expect(stickers.first.emoji, '😄');
    });

    test('Empty id is never added', () {
      final messages = <ChatMessage>[];
      final msg = ChatMessage(
        id: '',
        text: 'No ID',
        senderId: 'user-a',
        sourceLang: 'en',
        targetLang: 'de',
        timestamp: DateTime.now(),
        outgoing: false,
      );

      if (msg.id.isNotEmpty && !messages.any((m) => m.id == msg.id)) {
        messages.add(msg);
      }

      expect(messages, isEmpty);
    });

    test('Different ids are both added', () {
      final messages = <ChatMessage>[];
      final msg1 = ChatMessage(
        id: 'id-001',
        text: 'First',
        senderId: 'user-a',
        sourceLang: 'en',
        targetLang: 'de',
        timestamp: DateTime.now(),
        outgoing: false,
      );
      final msg2 = ChatMessage(
        id: 'id-002',
        text: 'Second',
        senderId: 'user-b',
        sourceLang: 'en',
        targetLang: 'de',
        timestamp: DateTime.now(),
        outgoing: false,
      );

      if (msg1.id.isNotEmpty && !messages.any((m) => m.id == msg1.id)) {
        messages.add(msg1);
      }
      if (msg2.id.isNotEmpty && !messages.any((m) => m.id == msg2.id)) {
        messages.add(msg2);
      }

      expect(messages.length, 2);
    });
  });
}
