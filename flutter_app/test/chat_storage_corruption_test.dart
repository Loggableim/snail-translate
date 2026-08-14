import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snail/services/chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps valid history entries when one entry is corrupt', () async {
    final writes = <String, String>{};
    final channel =
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final valid = <String, dynamic>{
      'messageId': 'good',
      'text': 'kept',
      'senderId': 'local',
      'sourceLang': 'de',
      'targetLang': 'en',
      'timestamp': 1000,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final key = (call.arguments as Map?)?['key'] as String?;
      if (call.method == 'read') {
        if (key?.startsWith('snail_conversation_') == true) {
          return jsonEncode({
            'messages': [
              valid,
              {...valid, 'messageId': 'bad', 'timestamp': 'broken'}
            ],
          });
        }
        return null;
      }
      if (call.method == 'write') {
        writes[key ?? ''] = (call.arguments as Map)['value'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final service = ChatService();
    await service.init('conversation', 'room');

    expect(service.messages, hasLength(1));
    expect(service.messages.single.id, 'good');
    expect(writes.keys.where((key) => key.contains('quarantine')), isEmpty);
  });
}
