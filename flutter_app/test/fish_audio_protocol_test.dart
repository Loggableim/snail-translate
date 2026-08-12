import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:snail/services/fish_audio_realtime_service.dart';

void main() {
  test('Fish realtime events use the documented MessagePack contract', () {
    final events = <Map<String, dynamic>>[
      {
        'event': 'start',
        'request': {
          'text': '',
          'format': 'pcm',
          'sample_rate': 24000,
          'reference_id': 'voice-id',
          'latency': 'balanced',
        },
      },
      {'event': 'text', 'text': 'Hello from a complete word group. '},
      {'event': 'flush'},
    ];

    for (final event in events) {
      final decoded = msgpack.deserialize(
          FishAudioRealtimeService.encodeEvent(event) as Uint8List);
      expect(decoded, event);
    }
  });
}
