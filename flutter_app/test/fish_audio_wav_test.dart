import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/fish_audio_asr_service.dart';

void main() {
  test('WAV header and PCM payload remain byte-identical', () {
    final pcm = Uint8List.fromList([0, 1, 2, 127, 128, 255]);
    final wav = FishAudioAsrService.buildWav(pcm, 16000);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.sublist(44), pcm);
    expect(wav.length, 44 + pcm.length);
  });
}
