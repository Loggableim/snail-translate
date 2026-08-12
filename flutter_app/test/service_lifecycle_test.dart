import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/audio_policy.dart';
import 'package:snail/services/chat_service.dart';
import 'package:snail/services/contact_service.dart';
import 'package:snail/services/snail_audio.dart';
import 'package:snail/services/web_socket_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioPolicy lifecycle', () {
    test('dispose does not throw', () {
      final policy = AudioPolicy();
      expect(() => policy.dispose(), returnsNormally);
    });

    test('throws when used after dispose', () {
      final policy = AudioPolicy();
      policy.dispose();
      expect(
        () => policy.setOutput(AudioOutput.speaker),
        throwsA(isA<FlutterError>()),
      );
    });
  });

  group('ChatService lifecycle', () {
    test('dispose does not throw', () {
      final service = ChatService();
      expect(() => service.dispose(), returnsNormally);
    });

    test('throws when used after dispose', () {
      final service = ChatService();
      service.dispose();
      expect(
        () => service.sendChat('test'),
        throwsA(isA<FlutterError>()),
      );
    });
  });

  group('ContactService lifecycle', () {
    test('dispose does not throw', () {
      final service = ContactService();
      expect(() => service.dispose(), returnsNormally);
    });
  });

  group('SnailAudio lifecycle', () {
    test('dispose does not throw when not capturing', () async {
      final audio = SnailAudio();
      await audio.dispose();
    });

    test('can be disposed multiple times', () async {
      final audio = SnailAudio();
      await audio.dispose();
      await audio.dispose();
    });
  });

  group('WebSocketTransport lifecycle', () {
    test('disconnect does not throw when not connected', () {
      final transport = WebSocketTransport();
      expect(() => transport.disconnect(), returnsNormally);
    });

    test('can be disconnected multiple times', () {
      final transport = WebSocketTransport();
      transport.disconnect();
      expect(() => transport.disconnect(), returnsNormally);
    });

    test('isConnected is false after disconnect', () {
      final transport = WebSocketTransport();
      transport.disconnect();
      expect(transport.isConnected, isFalse);
    });
  });
}
