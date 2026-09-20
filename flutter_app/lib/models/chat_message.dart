import 'message_status.dart';

/// What kind of content a chat entry carries.
enum ChatMessageKind { text, voice }

class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String sourceLang;
  final String targetLang;
  final DateTime timestamp;
  final bool outgoing;
  final MessageStatus status;

  /// Text or a voice note. Voice entries carry [audioData] instead of [text].
  final ChatMessageKind kind;

  /// Base64-encoded audio for a voice note; empty for text messages.
  final String audioData;

  /// MIME type of [audioData], e.g. `audio/pcm16`.
  final String mimeType;

  /// Sample rate of [audioData] in Hz.
  final int sampleRate;

  /// Duration of the recording in milliseconds.
  final int durationMs;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.sourceLang,
    required this.targetLang,
    required this.timestamp,
    required this.outgoing,
    this.status = MessageStatus.delivered,
    this.kind = ChatMessageKind.text,
    this.audioData = '',
    this.mimeType = 'audio/pcm16',
    this.sampleRate = 16000,
    this.durationMs = 0,
  });

  bool get isVoice => kind == ChatMessageKind.voice;

  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
        id: id,
        text: text,
        senderId: senderId,
        sourceLang: sourceLang,
        targetLang: targetLang,
        timestamp: timestamp,
        outgoing: outgoing,
        status: status ?? this.status,
        kind: kind,
        audioData: audioData,
        mimeType: mimeType,
        sampleRate: sampleRate,
        durationMs: durationMs,
      );

  Map<String, dynamic> toJson() => {
        'messageId': id,
        'text': text,
        'senderId': senderId,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.name,
        if (isVoice) ...{
          'audioData': audioData,
          'mimeType': mimeType,
          'sampleRate': sampleRate,
          'durationMs': durationMs,
        },
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json, String localUserId) {
    final audioData = json['audioData'] as String? ?? '';
    return ChatMessage(
      id: json['messageId'] as String? ?? '',
      text: json['text'] as String? ?? '',
      senderId: json['senderId'] as String? ?? '',
      sourceLang: json['sourceLang'] as String? ?? 'de',
      targetLang: json['targetLang'] as String? ?? 'en',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
          json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      // Matches the original comparison: an empty senderId with an empty
      // localUserId counts as outgoing, which is how the local-history
      // migration path marks its own entries.
      outgoing: (json['senderId'] as String? ?? '') == localUserId,
      status: MessageStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => MessageStatus.delivered),
      // A payload carrying audio is a voice note even if the sender did not
      // label it: the relay's voice message has no text field.
      kind: audioData.isNotEmpty
          ? ChatMessageKind.voice
          : ChatMessageKind.text,
      audioData: audioData,
      mimeType: json['mimeType'] as String? ?? 'audio/pcm16',
      sampleRate: json['sampleRate'] as int? ?? 16000,
      durationMs: json['durationMs'] as int? ?? 0,
    );
  }
}
