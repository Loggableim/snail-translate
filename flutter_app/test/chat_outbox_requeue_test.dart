import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/models/chat_message.dart';
import 'package:snail/services/chat_service.dart';

/// The chat outbox must never lose a message.
///
/// The transport can die between the `canSend()` check and the send itself.
/// Before this was handled, `_dispatch` marked the message in-flight and
/// dropped it — the message was gone with no error and no retry.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('refused sends are re-queued', () {
    test('a refused send stays in the outbox', () async {
      final service = ChatService();
      service.canSend = () => true;
      // The transport claims to be available but refuses the message, which is
      // what a socket closing mid-send looks like.
      service.onSend = (_) => false;

      await service.sendChat('Guten Tag', sourceLang: 'de', targetLang: 'en');

      expect(service.pendingCount, 1,
          reason: 'the refused message must be queued for retry');
      expect(service.messages.single.status.name, 'queued');
    });

    test('an accepted send is not queued', () async {
      final service = ChatService();
      service.canSend = () => true;
      service.onSend = (_) => true;

      await service.sendChat('Guten Tag', sourceLang: 'de', targetLang: 'en');

      expect(service.pendingCount, 0);
      expect(service.messages.single.status.name, 'sent');
    });

    test('a re-queued message is delivered on the next flush', () async {
      final service = ChatService();
      service.canSend = () => true;
      var accepting = false;
      final delivered = <String>[];
      service.onSend = (message) {
        if (!accepting) return false;
        delivered.add(message);
        return true;
      };

      await service.sendChat('Guten Tag', sourceLang: 'de', targetLang: 'en');
      expect(service.pendingCount, 1);

      // The transport recovers and the outbox is flushed.
      accepting = true;
      service.flushOutbox();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(delivered, hasLength(1));
      expect(delivered.single, contains('Guten Tag'));
    });

    test('a refused flush keeps the message queued for the next attempt',
        () async {
      final service = ChatService();
      service.canSend = () => true;
      service.onSend = (_) => false;

      await service.sendChat('Guten Tag', sourceLang: 'de', targetLang: 'en');
      service.flushOutbox();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      service.flushOutbox();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Still queued, not silently marked in-flight and skipped.
      expect(service.pendingCount, 1);
    });
  });

  group('voice notes', () {
    test('a sent voice note carries its audio and duration', () async {
      final service = ChatService();
      service.canSend = () => true;
      final wire = <Map<String, dynamic>>[];
      service.onSend = (message) {
        wire.add(jsonDecode(message) as Map<String, dynamic>);
        return true;
      };

      await service.sendVoice(
          audioData: base64Encode(List<int>.filled(64, 1)),
          durationMs: 1500,
          sourceLang: 'de',
          targetLang: 'en');

      expect(wire, hasLength(1));
      expect(wire.single['type'], 'voice');
      expect(wire.single['durationMs'], 1500);
      expect(wire.single['audioData'], isNotEmpty);
      expect(service.messages.single.isVoice, isTrue);
    });

    test('a refused voice note is queued, not lost', () async {
      final service = ChatService();
      service.canSend = () => true;
      service.onSend = (_) => false;

      await service.sendVoice(
          audioData: base64Encode(List<int>.filled(64, 1)), durationMs: 1500);

      expect(service.pendingCount, 1);
      expect(service.messages.single.isVoice, isTrue);
    });

    test('an empty recording is not sent', () async {
      final service = ChatService();
      service.canSend = () => true;
      var calls = 0;
      service.onSend = (_) {
        calls++;
        return true;
      };

      await service.sendVoice(audioData: '', durationMs: 0);

      expect(calls, 0);
      expect(service.messages, isEmpty);
    });

    test('an incoming voice payload is recognised as a voice note', () async {
      final service = ChatService();
      await service.addIncomingVoice({
        'type': 'voice',
        'messageId': 'voice-1',
        'senderId': 'peer',
        'audioData': base64Encode(List<int>.filled(32, 2)),
        'mimeType': 'audio/pcm16',
        'sampleRate': 16000,
        'durationMs': 2200,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final message = service.messages.single;
      expect(message.isVoice, isTrue);
      expect(message.durationMs, 2200);
      expect(message.audioData, isNotEmpty);
      expect(message.outgoing, isFalse);
    });

    test('a duplicate voice note is ignored', () async {
      final service = ChatService();
      final payload = {
        'type': 'voice',
        'messageId': 'voice-1',
        'senderId': 'peer',
        'audioData': base64Encode(List<int>.filled(32, 2)),
        'durationMs': 1000,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await service.addIncomingVoice(payload);
      await service.addIncomingVoice(payload);

      expect(service.messages, hasLength(1));
    });

    test('a voice note survives a JSON round trip', () {
      final original = ChatMessage(
        id: 'voice-1',
        text: '',
        senderId: 'local',
        sourceLang: 'de',
        targetLang: 'en',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        outgoing: true,
        kind: ChatMessageKind.voice,
        audioData: base64Encode(List<int>.filled(16, 3)),
        durationMs: 900,
      );

      final restored = ChatMessage.fromJson(original.toJson(), 'local');

      expect(restored.isVoice, isTrue);
      expect(restored.audioData, original.audioData);
      expect(restored.durationMs, 900);
      expect(restored.sampleRate, 16000);
    });

    test('a text message stays a text message', () {
      final restored = ChatMessage.fromJson({
        'messageId': 'text-1',
        'text': 'Guten Tag',
        'senderId': 'peer',
        'timestamp': 1000,
      }, '');

      expect(restored.isVoice, isFalse);
      expect(restored.text, 'Guten Tag');
    });
  });
}
