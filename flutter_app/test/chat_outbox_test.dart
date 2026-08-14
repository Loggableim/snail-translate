import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snail/models/message_status.dart';
import 'package:snail/services/chat_service.dart';

void main() {
  test('queues while relay is unauthenticated and flushes once', () {
    final service = ChatService();
    final sent = <String>[];
    service.onSend = sent.add;
    service.canSend = () => false;

    service.sendChat('offline');
    expect(service.pendingCount, 1);
    expect(service.messages.single.status, MessageStatus.queued);

    service.canSend = () => true;
    service.flushOutbox();
    service.flushOutbox();
    expect(sent, hasLength(1));
    expect((jsonDecode(sent.single) as Map<String, dynamic>)['text'], 'offline');
  });

  test('queues edit and delete operations while offline', () {
    final service = ChatService();
    service.onSend = (_) {};
    service.canSend = () => false;
    service.sendChat('before');
    final id = service.messages.single.id;

    service.editMessage(id, 'after');
    expect(service.messages.single.text, 'after');
    expect(service.pendingCount, 2);
    service.deleteMessage(id);
    expect(service.messages, isEmpty);
    expect(service.pendingCount, 3);
  });

  test('does not reserve queued messages before a send callback exists', () {
    final service = ChatService();
    service.canSend = () => true;
    service.sendChat('waiting for channel');
    expect(service.pendingCount, 1);

    service.flushOutbox();
    final sent = <String>[];
    service.onSend = sent.add;
    service.flushOutbox();

    expect(sent, hasLength(1));
  });
}
