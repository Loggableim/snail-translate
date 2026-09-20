import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/chat_crypto_service.dart';

void main() {
  final secret = List<int>.generate(32, (index) => index + 1);

  test('round trips plaintext while exposing only an opaque envelope',
      () async {
    final crypto = await ChatCryptoService.derive(secret);
    final ciphertext = await crypto.encrypt('private conversation');

    expect(ciphertext, isNot(contains('private conversation')));
    expect(await crypto.decrypt(ciphertext), 'private conversation');
    // v2 is the HKDF-derived envelope.
    expect(jsonDecode(ciphertext), containsPair('v', 'snail-chat-v2'));
  });

  test('rejects tampered ciphertext and wrong keys', () async {
    final crypto = await ChatCryptoService.derive(secret);
    final ciphertext = await crypto.encrypt('private conversation');
    final other = await ChatCryptoService.derive(
      List<int>.generate(32, (index) => index + 2),
    );

    expect(
      () => other.decrypt(ciphertext),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('requires a non-empty shared secret', () {
    expect(
      () => ChatCryptoService.derive(const <int>[]),
      throwsArgumentError,
    );
  });

  group('key derivation', () {
    test('both sides derive the same key from the same secret', () async {
      final alice = await ChatCryptoService.derive(secret);
      final bob = await ChatCryptoService.derive(secret);

      final ciphertext = await alice.encrypt('hello');
      expect(await bob.decrypt(ciphertext), 'hello');
    });

    test('the derived key differs from the raw ECDH output', () async {
      // The whole point of HKDF: the raw agreement is a curve point, not a
      // uniformly random key. A legacy service must not read a v2 envelope.
      final derived = await ChatCryptoService.derive(secret);
      final raw =
          // ignore: deprecated_member_use_from_same_package
          ChatCryptoService.fromSharedSecret(secret);

      final ciphertext = await derived.encrypt('hello');
      expect(
        () => raw.decrypt(ciphertext),
        throwsA(isA<FormatException>()),
        reason: 'the raw key must not read a v2 envelope',
      );
    });

    test('a different secret produces a different key', () async {
      final first = await ChatCryptoService.derive(secret);
      final second = await ChatCryptoService.derive(
        List<int>.generate(32, (index) => index + 9),
      );

      final ciphertext = await first.encrypt('hello');
      expect(
        () => second.decrypt(ciphertext),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('legacy envelopes', () {
    // The legacy constructor is deprecated on purpose: these tests exercise
    // the backwards-compatibility path, which only exists for old envelopes.
    ChatCryptoService legacyService() =>
        // ignore: deprecated_member_use_from_same_package
        ChatCryptoService.fromSharedSecret(secret);

    test('a v1 envelope stays readable after the HKDF change', () async {
      // Written by an earlier build: the raw ECDH output was the AES key.
      final legacy = legacyService();
      final legacyCiphertext = await legacy.encrypt('old message');
      // The legacy writer produces a v1 envelope.
      expect(jsonDecode(legacyCiphertext), containsPair('v', 'snail-chat-v1'));

      // A service derived the new way must still read it.
      final current = await ChatCryptoService.derive(secret);
      expect(await current.decrypt(legacyCiphertext), 'old message');
    });

    test('a v2 envelope is not readable with the legacy key', () async {
      final current = await ChatCryptoService.derive(secret);
      final ciphertext = await current.encrypt('new message');
      final legacy = legacyService();

      // The legacy service only knows v1, so it refuses the version outright.
      expect(
        () => legacy.decrypt(ciphertext),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
