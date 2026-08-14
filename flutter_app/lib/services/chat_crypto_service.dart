import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypts chat payloads before they cross a relay or P2P data channel.
///
/// The relay-facing value is a versioned JSON envelope. The envelope contains
/// no plaintext and can be decoded without possessing the conversation key.
class ChatCryptoService {
  static const _version = 'snail-chat-v1';
  static final _algorithm = AesGcm.with256bits();

  final SecretKey _key;

  ChatCryptoService.fromSharedSecret(List<int> sharedSecret)
      : _key = SecretKey(sharedSecret.length == 32
            ? List<int>.from(sharedSecret)
            : throw ArgumentError.value(
                sharedSecret.length, 'sharedSecret', 'must contain 32 bytes'));

  ChatCryptoService.fromBase64SharedSecret(String sharedSecret)
      : this.fromSharedSecret(base64Decode(sharedSecret));

  Future<String> encrypt(String plaintext) async {
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: _key,
    );
    return jsonEncode({
      'v': _version,
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'm': base64Url.encode(box.mac.bytes),
    });
  }

  Future<String> decrypt(String encoded) async {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic> || value['v'] != _version) {
      throw const FormatException('unsupported chat ciphertext version');
    }
    final nonce = _decode(value['n']);
    final cipherText = _decode(value['c']);
    final mac = Mac(_decode(value['m']));
    final plaintext = await _algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: _key,
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
