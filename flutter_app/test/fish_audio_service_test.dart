import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/fish_audio_realtime_service.dart';

void main() {
  test('voice can be selected before a realtime connection', () async {
    final service = FishAudioRealtimeService();
    await service.switchVoice('42039da0dcbd49bc8846fc1c12def1f4');
    expect(service.voiceId, '42039da0dcbd49bc8846fc1c12def1f4');
    service.dispose();
  });
}
