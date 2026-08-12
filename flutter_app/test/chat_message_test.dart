import 'package:flutter_test/flutter_test.dart';
import 'package:snail/models/chat_message.dart';
import 'package:snail/models/message_status.dart';

void main() {
  group('ChatMessage serialization', () {
    test('roundtrip preserves all fields including status', () {
      final original = ChatMessage(
        id: 'msg-001',
        text: 'Hallo Welt',
        senderId: 'user-abc',
        sourceLang: 'de',
        targetLang: 'en',
        timestamp: DateTime(2025, 1, 15, 10, 30),
        outgoing: true,
        status: MessageStatus.queued,
      );

      final json = original.toJson();
      final restored = ChatMessage.fromJson(json, 'user-abc');

      expect(restored.id, original.id);
      expect(restored.text, original.text);
      expect(restored.senderId, original.senderId);
      expect(restored.sourceLang, original.sourceLang);
      expect(restored.targetLang, original.targetLang);
      expect(restored.timestamp, original.timestamp);
      expect(restored.outgoing, isTrue);
      expect(restored.status, MessageStatus.queued);
    });

    test('fromJson defaults status to delivered when missing', () {
      final json = {
        'messageId': 'msg-002',
        'text': 'Test',
        'senderId': 'other',
        'sourceLang': 'en',
        'targetLang': 'de',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      final message = ChatMessage.fromJson(json, 'local');
      expect(message.status, MessageStatus.delivered);
    });

    test('fromJson parses all status values', () {
      for (final status in MessageStatus.values) {
        final json = {
          'messageId': 'msg-003',
          'text': 'Test',
          'senderId': 'other',
          'sourceLang': 'en',
          'targetLang': 'de',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'status': status.name,
        };

        final message = ChatMessage.fromJson(json, 'local');
        expect(message.status, status);
      }
    });

    test('copyWith updates status', () {
      final original = ChatMessage(
        id: 'msg-004',
        text: 'Test',
        senderId: 'local',
        sourceLang: 'de',
        targetLang: 'en',
        timestamp: DateTime.now(),
        outgoing: true,
        status: MessageStatus.queued,
      );

      final updated = original.copyWith(status: MessageStatus.delivered);
      expect(updated.status, MessageStatus.delivered);
      expect(updated.id, original.id);
      expect(updated.text, original.text);
    });

    test('toJson includes status field', () {
      final message = ChatMessage(
        id: 'msg-005',
        text: 'Test',
        senderId: 'local',
        sourceLang: 'de',
        targetLang: 'en',
        timestamp: DateTime.now(),
        outgoing: true,
        status: MessageStatus.sent,
      );

      final json = message.toJson();
      expect(json['status'], 'sent');
    });
  });
}
