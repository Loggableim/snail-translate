class StickerMessage {
  final String id;
  final String assetUrl;
  final String emoji;
  final String packShortName;
  final String mimeType;
  final bool outgoing;
  final String? stickerId;
  final String? fileUniqueId;
  final bool isAnimated;
  final bool isVideo;

  const StickerMessage(
      {required this.id,
      required this.assetUrl,
      required this.emoji,
      required this.packShortName,
      required this.mimeType,
      this.outgoing = true,
      this.stickerId,
      this.fileUniqueId,
      this.isAnimated = false,
      this.isVideo = false});

  factory StickerMessage.fromJson(Map<String, dynamic> json) => StickerMessage(
        id: json['messageId'] as String? ?? '',
        assetUrl: json['assetUrl'] as String? ?? '',
        emoji: json['emoji'] as String? ?? '🙂',
        packShortName: json['packShortName'] as String? ?? 'snail-local',
        mimeType: json['mimeType'] as String? ?? 'image/webp',
        outgoing: json['outgoing'] as bool? ?? false,
        stickerId: json['stickerId'] as String?,
        fileUniqueId: json['fileUniqueId'] as String?,
        isAnimated: json['isAnimated'] as bool? ?? false,
        isVideo: json['isVideo'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'messageId': id,
        'assetUrl': assetUrl,
        'emoji': emoji,
        'packShortName': packShortName,
        'mimeType': mimeType,
        'outgoing': outgoing,
        if (stickerId != null) 'stickerId': stickerId,
        if (fileUniqueId != null) 'fileUniqueId': fileUniqueId,
        'isAnimated': isAnimated,
        'isVideo': isVideo,
      };

  bool get isTelegramCompatible =>
      mimeType == 'image/webp' ||
      mimeType == 'application/x-tgsticker' ||
      mimeType == 'video/webm';
}
