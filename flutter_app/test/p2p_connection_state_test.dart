import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/p2p_audio_service.dart';

void main() {
  test('audio and chat connectivity require both peer and channel state', () {
    final state = P2pConnectionState();

    state.audioChannelOpen = true;
    expect(state.audioConnected, isFalse);
    state.peerConnected = true;
    expect(state.audioConnected, isTrue);
    state.peerConnected = false;
    expect(state.audioConnected, isFalse);

    state.peerConnected = true;
    state.chatChannelOpen = true;
    expect(state.chatConnected, isTrue);
    state.chatChannelOpen = false;
    expect(state.chatConnected, isFalse);
  });
}
