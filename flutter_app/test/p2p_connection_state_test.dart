import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/p2p_audio_service.dart';

void main() {
  test('audio and chat connectivity are derived independently', () {
    final state = P2pConnectionState();

    state.audioChannelOpen = true;
    expect(state.audioConnected, isFalse);
    state.peerConnected = true;
    expect(state.audioConnected, isTrue);
    expect(state.chatConnected, isFalse);

    state.chatChannelOpen = true;
    expect(state.chatConnected, isTrue);
    state.peerConnected = false;
    expect(state.audioConnected, isFalse);
    expect(state.chatConnected, isFalse);
  });

  test('event order produces the same final state', () {
    final peerThenAudio = P2pConnectionState()
      ..peerConnected = true
      ..audioChannelOpen = true;
    final audioThenPeer = P2pConnectionState()
      ..audioChannelOpen = true
      ..peerConnected = true;

    expect(peerThenAudio.audioConnected, isTrue);
    expect(audioThenPeer.audioConnected, isTrue);
  });
}
