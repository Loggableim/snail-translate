import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:snail/models/session.dart';
import 'package:snail/services/session_service.dart';

/// Records every request and answers with a scripted response per path.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.handler);

  final http.Response Function(http.BaseRequest request, String body) handler;
  final List<String> paths = <String>[];
  final List<String> bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    paths.add(request.url.path);
    bodies.add(body);
    final response = handler(request, body);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  group('Session model', () {
    test('parses mode and listener languages from a guide room response', () {
      final session = Session.fromJson({
        'roomId': 'snail-ABCD2345',
        'sessionToken': 'token',
        'relayUrl': 'wss://relay/ws?room=snail-ABCD2345',
        'sourceLang': 'de',
        'listenerLanguages': ['en', 'fr'],
        'mode': 'guide',
      }, role: 'listener');

      expect(session.mode, 'guide');
      expect(session.listenerLanguages, ['en', 'fr']);
      expect(session.role, 'listener');
    });

    test('defaults to duo mode when the response omits it', () {
      final session = Session.fromJson({
        'roomId': 'snail-ABCD2345',
        'sessionToken': 'token',
        'relayUrl': 'wss://relay/ws?room=snail-ABCD2345',
      });
      expect(session.mode, 'duo');
      expect(session.listenerLanguages, isEmpty);
    });

    test('copyWith preserves mode and listener languages', () {
      final session = Session.fromJson({
        'roomId': 'snail-ABCD2345',
        'sessionToken': 'token',
        'relayUrl': 'wss://relay/ws?room=snail-ABCD2345',
        'mode': 'guide',
        'listenerLanguages': ['en'],
      });
      final refreshed = session.copyWith(sessionToken: 'new-token');
      expect(refreshed.mode, 'guide');
      expect(refreshed.listenerLanguages, ['en']);
      expect(refreshed.sessionToken, 'new-token');
    });
  });

  group('SessionService guide rooms', () {
    test('creates a guide room with mode and listener languages', () async {
      final client = _ScriptedClient((request, body) {
        if (request.url.path == '/api/rooms') {
          return http.Response(
            jsonEncode({
              'roomId': 'snail-ABCD2345',
              'sessionToken': 'token',
              'relayUrl': 'wss://relay/ws?room=snail-ABCD2345',
              'sourceLang': 'de',
              'mode': 'guide',
              'listenerLanguages': ['en', 'fr'],
            }),
            201,
          );
        }
        return http.Response('{}', 404);
      });
      final service = SessionService(httpClient: client);
      addTearDown(service.dispose);

      final session = await service.createGuideRoom(listenerLanguages: ['en', 'fr']);

      expect(session, isNotNull);
      expect(session!.mode, 'guide');
      expect(session.role, 'host');
      final requestBody = jsonDecode(client.bodies.single) as Map<String, dynamic>;
      expect(requestBody['mode'], 'guide');
      expect(requestBody['listenerLanguages'], ['en', 'fr']);
    });

    test('joins a guide room as a listener through the listen endpoint', () async {
      final client = _ScriptedClient((request, body) {
        if (request.url.path == '/api/rooms/snail-ABCD2345/listen') {
          return http.Response(
            jsonEncode({
              'roomId': 'snail-ABCD2345',
              'sessionToken': 'token',
              'relayUrl': 'wss://relay/ws?room=snail-ABCD2345',
              'sourceLang': 'de',
              'listenerLanguages': ['en', 'fr'],
              'mode': 'guide',
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final service = SessionService(httpClient: client);
      addTearDown(service.dispose);

      final session = await service.joinAsListener('snail-ABCD2345');

      expect(session, isNotNull);
      expect(session!.role, 'listener');
      expect(session.mode, 'guide');
      expect(session.listenerLanguages, ['en', 'fr']);
      expect(client.paths, ['/api/rooms/snail-ABCD2345/listen']);
    });

    test('surfaces the guide-room code when a guest join is refused', () async {
      final client = _ScriptedClient((request, body) {
        if (request.url.path == '/api/rooms/snail-ABCD2345/join') {
          return http.Response(
            jsonEncode({
              'error': 'This is a listening room',
              'code': 'guide_room_use_listen',
            }),
            409,
          );
        }
        return http.Response('{}', 404);
      });
      final service = SessionService(httpClient: client);
      addTearDown(service.dispose);

      expect(await service.joinRoom('snail-ABCD2345'), isNull);
      expect(service.lastErrorCode, 'guide_room_use_listen');
      expect(service.errorCode, SessionFailureCode.guideRoomUseListen);
    });

    test('rejects a malformed room code before calling the worker', () async {
      final client = _ScriptedClient((request, body) => http.Response('{}', 200));
      final service = SessionService(httpClient: client);
      addTearDown(service.dispose);

      expect(await service.joinAsListener('not-a-room'), isNull);
      expect(service.errorCode, SessionFailureCode.invalidRoomCode);
      expect(client.paths, isEmpty);
    });

    test('maps a 409 on listen to a request failure', () async {
      final client = _ScriptedClient((request, body) =>
          http.Response(jsonEncode({'error': 'Not a listening room'}), 409));
      final service = SessionService(httpClient: client);
      addTearDown(service.dispose);

      expect(await service.joinAsListener('snail-ABCD2345'), isNull);
      expect(service.errorCode, SessionFailureCode.requestFailed);
    });
  });
}
