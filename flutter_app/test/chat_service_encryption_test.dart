import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/chat_crypto_service.dart';
import 'package:snail/services/chat_service.dart';

void main() {
  test('sends an encrypted text field when conversation crypto is configured',
      () async {
    final service = ChatService();
    service.setConversationCrypto(
        ChatCryptoService.fromSharedSecret(List<int>.filled(32, 7)));
    final wireMessages = <String>[];
    service.onSend = wireMessages.add;

    await service.sendChat('secret phrase');

    expect(wireMessages, hasLength(1));
    final wire = jsonDecode(wireMessages.single) as Map<String, dynamic>;
    expect(wire['text'], isNot('secret phrase'));
    expect(
      await ChatCryptoService.fromSharedSecret(List<int>.filled(32, 7))
          .decrypt(wire['text'] as String),
      'secret phrase',
    );
  });

  test('decrypts encrypted incoming messages and keeps legacy plaintext',
      () async {
    final crypto = ChatCryptoService.fromSharedSecret(List<int>.filled(32, 8));
    final service = ChatService()..setConversationCrypto(crypto);
    final encrypted = await crypto.encrypt('incoming secret');

    await service.addIncomingChatSecure({
      'type': 'chat',
      'messageId': 'encrypted-message',
      'text': encrypted,
      'timestamp': 1,
    });
    await service.addIncomingChatSecure({
      'type': 'chat',
      'messageId': 'legacy-message',
      'text': 'old plaintext',
      'timestamp': 2,
    });

    expect(service.messages.map((message) => message.text),
        containsAll(<String>['incoming secret', 'old plaintext']));
  });

  test('encrypts a plaintext chat that was queued before key exchange',
      () async {
    final service = ChatService();
    final wireMessages = <String>[];
    service.onSend = wireMessages.add;
    service.canSend = () => false;
    service.sendChat('queued secret');
    service.setConversationCrypto(
        ChatCryptoService.fromSharedSecret(List<int>.filled(32, 9)));
    service.canSend = () => true;

    await Future<void>.delayed(Duration.zero);
    service.flushOutbox();
    await Future<void>.delayed(Duration.zero);

    final wire = jsonDecode(wireMessages.single) as Map<String, dynamic>;
    expect(wire['text'], isNot('queued secret'));
  });
}
