import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/snail_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects missing-equivalent invalid sample rates before platform call',
      () async {
    final calls = <MethodCall>[];
    final channel = const MethodChannel('com.snail.audio/method');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final audio = SnailAudio();
    expect(await audio.initialize(sampleRate: 0), isFalse);
    expect(await audio.startStandaloneCapture(sampleRate: 192001), isFalse);
    await audio.playPcm16(Uint8List.fromList([0, 0]), sampleRate: -1);

    expect(calls, isEmpty);
  });

  test('forwards valid sample rates to the platform', () async {
    final calls = <MethodCall>[];
    final channel = const MethodChannel('com.snail.audio/method');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final audio = SnailAudio();
    expect(await audio.initialize(sampleRate: 16000), isTrue);

    final initializeCall =
        calls.firstWhere((call) => call.method == 'initialize');
    expect(initializeCall.arguments['sampleRate'], 16000);
  });
}
