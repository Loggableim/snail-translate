class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String sourceLang;
  final String targetLang;
  final DateTime timestamp;
  final bool outgoing;

  const ChatMessage(
      {required this.id,
      required this.text,
      required this.senderId,
      required this.sourceLang,
      required this.targetLang,
      required this.timestamp,
      required this.outgoing});

  Map<String, dynamic> toJson() => {
        'messageId': id,
        'text': text,
        'senderId': senderId,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'timestamp': timestamp.millisecondsSinceEpoch,
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
      );
}
