import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Turns a conversation key into a short string two people can compare.
///
/// The relay hands each side the other's public key. Nothing in that exchange
/// proves the key really belongs to the peer: a malicious relay could hand out
/// its own key to both sides and read everything (a man-in-the-middle). The
/// only defence that does not require trusting the relay is for both people to
/// compare a fingerprint of the derived conversation key over a channel the
/// relay does not control — reading it aloud, or scanning a QR code.
///
/// If the fingerprints match, no relay sat in the middle. If they differ, the
/// conversation is compromised and must not be used.
class KeyFingerprint {
  /// Derives the fingerprint both sides must agree on.
  ///
  /// The input is the *conversation key* rather than the public keys, so the
  /// value only matches when both sides derived the same secret — a relay that
  /// substituted its own key produces a different fingerprint on each side.
  static Future<KeyFingerprint> fromSharedSecret(List<int> sharedSecret) async {
    if (sharedSecret.isEmpty) {
      throw ArgumentError.value(
          sharedSecret, 'sharedSecret', 'must not be empty');
    }
    // A separate HKDF context: the fingerprint must not be computable from the
    // encryption key, so a leaked fingerprint cannot weaken the ciphertext.
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: const <int>[],
      info: utf8.encode('snail-chat-v1-fingerprint'),
    );
    final bytes = await derived.extractBytes();
    return KeyFingerprint._(Uint8List.fromList(bytes));
  }

  static Future<KeyFingerprint> fromBase64SharedSecret(
          String sharedSecret) =>
      fromSharedSecret(base64Decode(sharedSecret));

  KeyFingerprint._(this._bytes);

  final Uint8List _bytes;

  /// Twelve groups of five digits — the Signal-style safety number.
  ///
  /// Digits are used instead of hex because people read them aloud and compare
  /// them by eye; `4F2A` is easy to mishear, `48291` is not.
  String get digits {
    final buffer = StringBuffer();
    var produced = 0;
    var index = 0;
    while (produced < 12) {
      // Take two bytes at a time and reduce to a 5-digit group.
      final high = _bytes[index % _bytes.length];
      final low = _bytes[(index + 1) % _bytes.length];
      final value = ((high << 8) | low) % 100000;
      if (produced > 0) buffer.write(' ');
      buffer.write(value.toString().padLeft(5, '0'));
      produced++;
      index += 2;
    }
    return buffer.toString();
  }

  /// Compact form for a QR code or a copy-paste.
  String get compact => _bytes
      .take(16)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  /// True when both sides derived the same conversation key.
  bool matches(KeyFingerprint other) {
    if (_bytes.length != other._bytes.length) return false;
    // Constant-time comparison: a timing difference would leak how many
    // leading bytes matched, which is enough to reconstruct the value byte by
    // byte.
    var difference = 0;
    for (var index = 0; index < _bytes.length; index++) {
      difference |= _bytes[index] ^ other._bytes[index];
    }
    return difference == 0;
  }

  @override
  String toString() => digits;
}
