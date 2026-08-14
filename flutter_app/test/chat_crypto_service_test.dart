import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/chat_crypto_service.dart';

void main() {
  final secret = List<int>.generate(32, (index) => index + 1);

  test('round trips plaintext while exposing only an opaque envelope',
      () async {
    final crypto = ChatCryptoService.fromSharedSecret(secret);
    final ciphertext = await crypto.encrypt('private conversation');

    expect(ciphertext, isNot(contains('private conversation')));
    expect(await crypto.decrypt(ciphertext), 'private conversation');
    expect(jsonDecode(ciphertext), containsPair('v', 'snail-chat-v1'));
  });

  test('rejects tampered ciphertext and wrong keys', () async {
    final crypto = ChatCryptoService.fromSharedSecret(secret);
    final ciphertext = await crypto.encrypt('private conversation');
    final other = ChatCryptoService.fromSharedSecret(
      List<int>.generate(32, (index) => index + 2),
    );

    expect(
      () => other.decrypt(ciphertext),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('requires a 256-bit conversation key', () {
    expect(
      () => ChatCryptoService.fromSharedSecret(List<int>.filled(31, 0)),
      throwsArgumentError,
    );
  });
}
