import 'message_status.dart';

class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String sourceLang;
  final String targetLang;
  final DateTime timestamp;
  final bool outgoing;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.sourceLang,
    required this.targetLang,
    required this.timestamp,
    required this.outgoing,
    this.status = MessageStatus.delivered,
  });

  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
        id: id,
        text: text,
        senderId: senderId,
        sourceLang: sourceLang,
        targetLang: targetLang,
        timestamp: timestamp,
        outgoing: outgoing,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'messageId': id,
        'text': text,
        'senderId': senderId,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.name,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json, String localUserId) =>
      ChatMessage(
        id: json['messageId'] as String? ?? '',
        text: json['text'] as String? ?? '',
        senderId: json['senderId'] as String? ?? '',
        sourceLang: json['sourceLang'] as String? ?? 'de',
        targetLang: json['targetLang'] as String? ?? 'en',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch),
        outgoing: (json['senderId'] as String?) == localUserId,
        status: _parseStatus(json['status'] as String?),
      );

  static MessageStatus _parseStatus(String? raw) {
    if (raw == null) return MessageStatus.delivered;
    return MessageStatus.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => MessageStatus.delivered,
    );
  }
}
