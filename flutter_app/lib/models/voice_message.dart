/// A recorded voice message sent via the chat.
///
/// Voice messages are short audio recordings (max 60 seconds) that are
/// transmitted as base64-encoded PCM16 or Opus data.
class VoiceMessage {
  final String id;
  final String senderId;
  final String audioData; // base64-encoded audio bytes
  final String mimeType; // 'audio/pcm16' | 'audio/opus' | 'audio/webm'
  final int sampleRate;
  final int durationMs;
  final DateTime timestamp;
  final bool outgoing;
  final String status; // 'queued' | 'sent' | 'delivered' | 'read'

  const VoiceMessage({
    required this.id,
    required this.senderId,
    required this.audioData,
    this.mimeType = 'audio/pcm16',
    this.sampleRate = 16000,
    required this.durationMs,
    required this.timestamp,
    this.outgoing = true,
    this.status = 'delivered',
  });

  factory VoiceMessage.fromJson(Map<String, dynamic> json) => VoiceMessage(
        id: json['messageId'] as String? ?? '',
        senderId: json['senderId'] as String? ?? '',
        audioData: json['audioData'] as String? ?? '',
        mimeType: json['mimeType'] as String? ?? 'audio/pcm16',
        sampleRate: json['sampleRate'] as int? ?? 16000,
        durationMs: json['durationMs'] as int? ?? 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch),
        outgoing: json['outgoing'] as bool? ?? false,
        status: json['status'] as String? ?? 'delivered',
      );

  Map<String, dynamic> toJson() => {
        'messageId': id,
        'senderId': senderId,
        'audioData': audioData,
        'mimeType': mimeType,
        'sampleRate': sampleRate,
        'durationMs': durationMs,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'outgoing': outgoing,
        'status': status,
      };
}
