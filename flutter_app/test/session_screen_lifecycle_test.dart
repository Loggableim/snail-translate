import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/snail_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SnailAudio lifecycle', () {
    late List<MethodCall> methodCalls;

    setUp(() {
      methodCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.snail.audio/method'),
        (call) async {
          methodCalls.add(call);
          return true;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.snail.audio/method'),
        null,
      );
    });

    test('pauseCapture calls native method', () async {
      final audio = SnailAudio();
      // Simulate initialized + capturing state by calling startCapture
      await audio.initialize();
      await audio.startCapture();

      methodCalls.clear();
      await audio.pauseCapture();

      expect(
        methodCalls.any((c) => c.method == 'pauseCapture'),
        isTrue,
      );
    });

    test('resumeCapture calls native method', () async {
      final audio = SnailAudio();
      await audio.initialize();
      await audio.startCapture();

      methodCalls.clear();
      await audio.resumeCapture();

      expect(
        methodCalls.any((c) => c.method == 'resumeCapture'),
        isTrue,
      );
    });

    test('pauseCapture is a no-op when not capturing', () async {
      final audio = SnailAudio();
      await audio.initialize();

      methodCalls.clear();
      await audio.pauseCapture();

      expect(
        methodCalls.any((c) => c.method == 'pauseCapture'),
        isFalse,
      );
    });

    test('resumeCapture is a no-op when not capturing', () async {
      final audio = SnailAudio();
      await audio.initialize();

      methodCalls.clear();
      await audio.resumeCapture();

      expect(
        methodCalls.any((c) => c.method == 'resumeCapture'),
        isFalse,
      );
    });

    test('playPcm16 sends PCM as a typed byte list', () async {
      final audio = SnailAudio();
      await audio.initialize();

      methodCalls.clear();
      await audio.playPcm16(Uint8List.fromList([1, 2, 3, 4]), sampleRate: 24000);

      final call = methodCalls.singleWhere((c) => c.method == 'playPcm16');
      final bytes = (call.arguments as Map)['bytes'];
      // Passing a plain List<int> here boxes every sample into an Integer on
      // both sides of the channel — tens of thousands of short-lived objects
      // per chunk, which made playback stutter under GC pressure. The
      // standard codec maps Uint8List straight to a Java byte[].
      expect(bytes, isA<Uint8List>());
      expect(bytes, [1, 2, 3, 4]);
    });
  });
}
