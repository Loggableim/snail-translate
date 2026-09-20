import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypts chat payloads before they cross a relay or P2P data channel.
///
/// The relay-facing value is a versioned JSON envelope. The envelope contains
/// no plaintext and can be decoded without possessing the conversation key.
class ChatCryptoService {
  /// Current envelope version. `v2` derives the AES key through HKDF; `v1`
  /// used the raw ECDH output directly.
  static const _version = 'snail-chat-v2';

  /// Envelopes written before the HKDF change. They stay readable so an
  /// existing conversation history does not become unreadable.
  static const _legacyVersion = 'snail-chat-v1';

  static final _algorithm = AesGcm.with256bits();

  /// Context string mixed into the key derivation.
  ///
  /// Binding the key to a purpose means the same ECDH secret cannot produce
  /// the same AES key in two different places, so a key derived here can never
  /// collide with one derived for another feature.
  static const _info = 'snail-chat-v1-encryption';

  final SecretKey _key;

  /// Legacy key: the raw ECDH output, used only to read `v1` envelopes.
  final SecretKey? _legacyKey;

  /// True when this service writes the pre-HKDF envelope format.
  ///
  /// Only the deprecated constructor sets it, so a service built the old way
  /// keeps producing envelopes the old way — which is what makes the legacy
  /// path testable and keeps an old build's output readable.
  final bool _writesLegacyEnvelopes;

  ChatCryptoService._(this._key, this._legacyKey, this._writesLegacyEnvelopes);

  /// Derives the conversation key from a raw ECDH shared secret.
  ///
  /// The raw output of an ECDH agreement is **not** uniformly random — it is a
  /// point on a curve, and its structure can leak information about the
  /// secret. Running it through HKDF first is what makes it a proper
  /// cryptographic key. Using the raw bytes as an AES key (as `v1` did) is a
  /// known mistake, not merely a stylistic one.
  static Future<ChatCryptoService> derive(List<int> sharedSecret) async {
    if (sharedSecret.isEmpty) {
      throw ArgumentError.value(sharedSecret, 'sharedSecret', 'must not be empty');
    }
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: const <int>[], // no salt: both sides must derive the same key
      info: utf8.encode(_info),
    );
    return ChatCryptoService._(
      derived,
      // Kept so `v1` envelopes from an earlier build stay readable.
      sharedSecret.length == 32 ? SecretKey(List<int>.from(sharedSecret)) : null,
      false,
    );
  }

  /// Derives from a base64 ECDH shared secret, as the native layer returns it.
  static Future<ChatCryptoService> fromBase64SharedSecret(
          String sharedSecret) =>
      derive(base64Decode(sharedSecret));

  /// Synchronous constructor kept for callers that already hold a 32-byte
  /// secret and do not need the legacy read path.
  @Deprecated('Use ChatCryptoService.derive() so the key goes through HKDF')
  ChatCryptoService.fromSharedSecret(List<int> sharedSecret)
      : _key = SecretKey(sharedSecret.length == 32
            ? List<int>.from(sharedSecret)
            : throw ArgumentError.value(
                sharedSecret.length, 'sharedSecret', 'must contain 32 bytes')),
        _legacyKey = null,
        // Writes the old envelope so the legacy read path stays exercised.
        _writesLegacyEnvelopes = true;

  Future<String> encrypt(String plaintext) async {
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: _key,
    );
    return jsonEncode({
      'v': _writesLegacyEnvelopes ? _legacyVersion : _version,
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'm': base64Url.encode(box.mac.bytes),
    });
  }

  Future<String> decrypt(String encoded) async {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('unsupported chat ciphertext version');
    }
    final version = value['v'];
    final SecretKey key;
    if (version == _version) {
      // A service built the legacy way holds the raw ECDH bytes, not the
      // HKDF output, so it cannot read a v2 envelope at all.
      if (_writesLegacyEnvelopes) {
        throw const FormatException('unsupported chat ciphertext version');
      }
      key = _key;
    } else if (version == _legacyVersion && _legacyKey != null) {
      // Written before the HKDF change; readable so old history survives.
      key = _legacyKey;
    } else {
      throw const FormatException('unsupported chat ciphertext version');
    }
    final nonce = _decode(value['n']);
    final cipherText = _decode(value['c']);
    final mac = Mac(_decode(value['m']));
    final plaintext = await _algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
    return utf8.decode(plaintext);
  }

  static Uint8List _decode(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('invalid chat ciphertext field');
    }
    try {
      return Uint8List.fromList(base64Url.decode(value));
    } catch (_) {
      throw const FormatException('invalid chat ciphertext encoding');
    }
  }
}
