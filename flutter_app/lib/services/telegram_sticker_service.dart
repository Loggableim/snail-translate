import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/sticker_message.dart';

/// Optional Telegram Bot API adapter for public sticker packs.
///
/// The bot token is used only for the two short-lived fetches below. It is
/// never put into StickerMessage or sent through the Snail relay.
class TelegramStickerService {
  static const _maxStickersPerPack = 100;
  static const _maxAssetBytes = 512 * 1024;

  Future<List<StickerMessage>> importPack({
    required String botToken,
    required String packLink,
  }) async {
    final token = botToken.trim();
    final pack = _packName(packLink);
    if (token.isEmpty || pack == null) {
      throw const FormatException('Telegram-Pack-Link oder Bot-Token fehlt');
    }

    final setResponse = await http.get(Uri.parse(
      'https://api.telegram.org/bot$token/getStickerSet?name=${Uri.encodeQueryComponent(pack)}',
    ));
    final setJson = _json(setResponse);
    final stickers =
        (setJson['result']?['stickers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>();
    final result = <StickerMessage>[];
    var importedCount = 0;
    for (final sticker in stickers) {
      if (importedCount >= _maxStickersPerPack) break;
      final fileId = sticker['file_id'] as String?;
      if (fileId == null || fileId.isEmpty) continue;
      final fileResponse = await http.get(Uri.parse(
        'https://api.telegram.org/bot$token/getFile?file_id=${Uri.encodeQueryComponent(fileId)}',
      ));
      final fileJson = _json(fileResponse);
      final path = fileJson['result']?['file_path'] as String?;
      if (path == null || path.isEmpty) continue;
      final assetResponse = await http.get(Uri.parse(
        'https://api.telegram.org/file/bot$token/$path',
      ));
      if (assetResponse.statusCode < 200 || assetResponse.statusCode >= 300) {
        continue;
      }
      if (assetResponse.bodyBytes.length > _maxAssetBytes) continue;
      final animated = sticker['is_animated'] == true;
      final video = sticker['is_video'] == true;
      final mime = video
          ? 'video/webm'
          : (animated ? 'application/x-tgsticker' : 'image/webp');
      result.add(StickerMessage(
        id: 'telegram-${sticker['file_unique_id'] ?? fileId}',
        assetUrl: _dataUrl(mime, assetResponse.bodyBytes),
        emoji: sticker['emoji'] as String? ?? '🙂',
        packShortName: pack,
        mimeType: mime,
        stickerId: fileId,
        fileUniqueId: sticker['file_unique_id'] as String?,
        isAnimated: animated,
        isVideo: video,
      ));
      importedCount++;
    }
    return result;
  }

  String? _packName(String value) {
    final trimmed = value.trim();
    if (trimmed.contains('/')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.host == 't.me') {
        final parts = uri.pathSegments;
        if (parts.length >= 2 && parts.first == 'addstickers') return parts[1];
      }
    }
    return RegExp(r'^[A-Za-z0-9_]+$').hasMatch(trimmed) ? trimmed : null;
  }

  Map<String, dynamic> _json(http.Response response) {
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['ok'] != true) {
      throw StateError(
          decoded['description'] as String? ?? 'Telegram API Fehler');
    }
    return decoded;
  }

  String _dataUrl(String mime, Uint8List bytes) =>
      'data:$mime;base64,${base64Encode(bytes)}';
}
