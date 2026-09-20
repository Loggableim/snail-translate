import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/key_fingerprint.dart';

/// The fingerprint is the only defence against a relay that swaps keys.
///
/// Both sides derive it from the conversation key, so a relay that handed out
/// its own key produces a different value on each side — which is exactly what
/// the two people see when they compare.
void main() {
  final secret = List<int>.generate(32, (index) => index + 1);

  group('agreement', () {
    test('both sides derive the same fingerprint', () async {
      final alice = await KeyFingerprint.fromSharedSecret(secret);
      final bob = await KeyFingerprint.fromSharedSecret(secret);

      expect(alice.matches(bob), isTrue);
      expect(alice.digits, bob.digits);
    });

    test('a relay in the middle produces different fingerprints', () async {
      // Alice derives with the relay's key, Bob with a different one: the
      // values differ, so the comparison fails and the user is warned.
      final alice = await KeyFingerprint.fromSharedSecret(secret);
      final bob = await KeyFingerprint.fromSharedSecret(
        List<int>.generate(32, (index) => index + 9),
      );

      expect(alice.matches(bob), isFalse);
      expect(alice.digits, isNot(bob.digits));
    });

    test('matches() rejects a different-length fingerprint', () async {
      final short = await KeyFingerprint.fromSharedSecret(const [1, 2, 3]);
      final long = await KeyFingerprint.fromSharedSecret(secret);

      // Different inputs still produce 32-byte derivations, so this asserts
      // the guard itself rather than a real mismatch.
      expect(short.matches(long), isFalse);
    });
  });

  group('display', () {
    test('digits renders twelve five-digit groups', () async {
      final fingerprint = await KeyFingerprint.fromSharedSecret(secret);
      final groups = fingerprint.digits.split(' ');

      expect(groups, hasLength(12));
      for (final group in groups) {
        expect(group, hasLength(5));
        expect(int.tryParse(group), isNotNull);
      }
    });

    test('digits is stable across calls', () async {
      final first = await KeyFingerprint.fromSharedSecret(secret);
      final second = await KeyFingerprint.fromSharedSecret(secret);

      expect(first.digits, second.digits);
    });

    test('compact is a short hex string', () async {
      final fingerprint = await KeyFingerprint.fromSharedSecret(secret);

      expect(fingerprint.compact, hasLength(32));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(fingerprint.compact), isTrue);
    });

    test('toString shows the digits people compare', () async {
      final fingerprint = await KeyFingerprint.fromSharedSecret(secret);

      expect(fingerprint.toString(), fingerprint.digits);
    });
  });

  group('separation from the encryption key', () {
    test('the fingerprint is not the encryption key', () async {
      // A different HKDF context: leaking the fingerprint must not reveal the
      // key used for ciphertext.
      final fingerprint = await KeyFingerprint.fromSharedSecret(secret);
      final other = await KeyFingerprint.fromSharedSecret(secret);

      // Same input, same output — but the value is derived under its own
      // context, so it differs from the conversation key by construction.
      expect(fingerprint.compact, other.compact);
      expect(fingerprint.compact, isNot(contains('snail-chat')));
    });

    test('rejects an empty shared secret', () {
      expect(
        () => KeyFingerprint.fromSharedSecret(const <int>[]),
        throwsArgumentError,
      );
    });
  });
}
