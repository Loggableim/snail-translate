import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/chat_service.dart';

void main() {
  ChatService serviceWithIncoming() {
    final service = ChatService();
    service.addIncomingChat({
      'type': 'chat',
      'messageId': 'peer-message',
      'text': 'original text',
      'senderId': 'peer',
      'sourceLang': 'de',
      'targetLang': 'en',
      'timestamp': 1,
    });
    service.addIncomingChat({
      'type': 'chat',
      'messageId': 'local-message',
      'text': 'my own text',
      'senderId': '',
      'sourceLang': 'de',
      'targetLang': 'en',
      'timestamp': 2,
    });
    return service;
  }

  test('applyRemoteEdit replaces the text of an incoming message', () {
    final service = serviceWithIncoming();
    service.applyRemoteEdit(
        {'type': 'edit', 'messageId': 'peer-message', 'text': 'edited text'});
    expect(
      service.messages.firstWhere((m) => m.id == 'peer-message').text,
      'edited text',
    );
  });

  test('applyRemoteEdit ignores edits targeting an outgoing message', () {
    final service = serviceWithIncoming();
    service.applyRemoteEdit(
        {'type': 'edit', 'messageId': 'local-message', 'text': 'hacked'});
    expect(
      service.messages.firstWhere((m) => m.id == 'local-message').text,
      'my own text',
    );
  });

  test('applyRemoteEdit ignores unknown ids and empty text', () {
    final service = serviceWithIncoming();
    service.applyRemoteEdit({'type': 'edit', 'messageId': 'missing', 'text': 'x'});
    service.applyRemoteEdit({'type': 'edit', 'messageId': 'peer-message'});
    service.applyRemoteEdit(
        {'type': 'edit', 'messageId': 'peer-message', 'text': '   '});
    expect(
      service.messages.firstWhere((m) => m.id == 'peer-message').text,
      'original text',
    );
  });

  test('applyRemoteDelete removes an incoming message', () {
    final service = serviceWithIncoming();
    service.applyRemoteDelete({'type': 'delete', 'messageId': 'peer-message'});
    expect(
      service.messages.any((m) => m.id == 'peer-message'),
      isFalse,
    );
    expect(service.messages.any((m) => m.id == 'local-message'), isTrue);
  });

  test('applyRemoteDelete ignores deletes targeting an outgoing message', () {
    final service = serviceWithIncoming();
    service.applyRemoteDelete({'type': 'delete', 'messageId': 'local-message'});
    expect(service.messages.any((m) => m.id == 'local-message'), isTrue);
  });
}