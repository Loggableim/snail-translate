import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Direct peer transport for already-translated PCM audio.
///
/// The Worker/DO remains responsible for exchanging SDP and ICE messages. No
/// provider key or untranslated microphone audio is sent through this data
/// channel. If ICE fails, SessionScreen can continue using AudioService's
/// relay PCM fallback.
class P2pAudioService {
  RTCPeerConnection? _peer;
  RTCDataChannel? _audioChannel;
  RTCDataChannel? _chatChannel;
  StreamSubscription? _signalSubscription;
  bool _isInitiator = false;
  bool _connected = false;
  void Function(String type, dynamic signal)? onSignal;
  void Function(Uint8List bytes, int sampleRate)? onAudio;
  VoidCallback? onAudioEnd;
  void Function(Map<String, dynamic> message)? onChat;

  bool get isConnected => _connected;

  Future<void> start(
      {required bool initiator,
      List<Map<String, dynamic>> iceServers = const []}) async {
    _isInitiator = initiator;
    _peer = await createPeerConnection({
      'iceServers': iceServers.isEmpty
          ? [
              {'urls': 'stun:stun.l.google.com:19302'},
            ]
          : iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _peer!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onSignal?.call('ice', {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };
    _peer!.onConnectionState = (state) {
      _connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
    };
    _peer!.onDataChannel = _acceptDataChannel;

    if (_isInitiator) {
      _audioChannel = await _peer!
          .createDataChannel('translated-audio', RTCDataChannelInit());
      _acceptAudioChannel(_audioChannel!);
      _chatChannel =
          await _peer!.createDataChannel('snail-chat', RTCDataChannelInit());
      _acceptChatChannel(_chatChannel!);
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      onSignal?.call('offer', {'type': offer.type, 'sdp': offer.sdp});
    }
  }

  void _acceptAudioChannel(RTCDataChannel channel) {
    _audioChannel = channel;
    channel.onDataChannelState = (state) {
      _connected = state == RTCDataChannelState.RTCDataChannelOpen;
    };
    channel.onMessage = (message) {
      if (!message.isBinary) return;
      final bytes = message.binary;
      if (bytes.length < 4) return;
      final sampleRate =
          ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.little);
      if (bytes.length == 4) {
        onAudioEnd?.call();
        return;
      }
      onAudio?.call(Uint8List.sublistView(bytes, 4), sampleRate);
    };
  }

  void _acceptDataChannel(RTCDataChannel channel) {
    if (channel.label == 'snail-chat') {
      _acceptChatChannel(channel);
    } else {
      _acceptAudioChannel(channel);
    }
  }

  void _acceptChatChannel(RTCDataChannel channel) {
    _chatChannel = channel;
    channel.onMessage = (message) {
      if (message.isBinary) return;
      try {
        final value = jsonDecode(message.text);
        if (value is Map<String, dynamic>) onChat?.call(value);
      } catch (_) {}
    };
  }

  Future<void> acceptSignal(String type, dynamic signal) async {
    final peer = _peer;
    if (peer == null) return;
    final data = Map<String, dynamic>.from(signal as Map);
    if (type == 'offer') {
      await peer.setRemoteDescription(RTCSessionDescription(
          data['sdp'] as String?, data['type'] as String?));
      final answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      onSignal?.call('answer', {'type': answer.type, 'sdp': answer.sdp});
    } else if (type == 'answer') {
      await peer.setRemoteDescription(RTCSessionDescription(
          data['sdp'] as String?, data['type'] as String?));
    } else if (type == 'ice') {
      await peer.addCandidate(RTCIceCandidate(data['candidate'] as String?,
          data['sdpMid'] as String?, data['sdpMLineIndex'] as int?));
    }
  }

  void sendPcm16(Uint8List bytes, {int sampleRate = 24000}) {
    final channel = _audioChannel;
    if (channel == null || bytes.isEmpty || !_connected) return;
    final payload = Uint8List(4 + bytes.length);
    ByteData.sublistView(payload, 0, 4).setUint32(0, sampleRate, Endian.little);
    payload.setRange(4, payload.length, bytes);
    channel.send(RTCDataChannelMessage.fromBinary(payload));
  }

  /// Ordered four-byte control frame marking the end of a translated stream.
  /// It lets the receiver play a short final chunk without using a timer.
  void sendPcmEnd() {
    final channel = _audioChannel;
    if (channel == null || !_connected) return;
    channel.send(RTCDataChannelMessage.fromBinary(Uint8List(4)));
  }

  void sendChat(Map<String, dynamic> message) {
    sendData(message);
  }

  void sendData(Map<String, dynamic> message) {
    final channel = _chatChannel;
    if (channel == null || !_connected) return;
    channel.send(RTCDataChannelMessage(jsonEncode(message)));
  }

  Future<void> dispose() async {
    await _signalSubscription?.cancel();
    await _audioChannel?.close();
    await _chatChannel?.close();
    await _peer?.close();
    _audioChannel = null;
    _chatChannel = null;
    _peer = null;
    _connected = false;
  }
}
