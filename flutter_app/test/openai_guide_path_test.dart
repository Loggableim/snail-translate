import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:snail/services/openai_realtime_service.dart';

/// A local WebSocket server that speaks the realtime translation protocol.
///
/// The guide's OpenAI path could only be exercised against the live API, which
/// needs a real key. This mock answers the same message types the service
/// handles, so the protocol wiring — turn completion, transcript deltas,
/// audio deltas — is testable end to end.
class _MockRealtimeServer {
  _MockRealtimeServer(this._server);

  final HttpServer _server;
  final List<String> received = <String>[];
  WebSocket? _socket;

  static Future<_MockRealtimeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = _MockRealtimeServer(server);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      mock._socket = socket;
      socket.listen((data) {
        mock.received.add(data is String ? data : '<binary>');
        mock._onClientMessage(data);
      });
    });
    return mock;
  }

  int get port => _server.port;

  String get url => 'ws://127.0.0.1:$port/v1/realtime/translations';

  void _onClientMessage(dynamic data) {
    if (data is! String) return;
    final message = jsonDecode(data) as Map<String, dynamic>;
    // The service sends session.close on disconnect; acknowledge it so the
    // drain completes instead of timing out.
    if (message['type'] == 'session.close') {
      _send({'type': 'session.closed'});
    }
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null) return;
    // The client may be tearing the socket down while we answer; a closed
    // sink is expected then, not a test failure.
    try {
      socket.add(jsonEncode(message));
    } catch (_) {}
  }

  /// Emits one complete translated turn, the way the live endpoint does.
  ///
  /// The service finalises a turn 900 ms after `speech_stopped`, so callers
  /// must wait longer than that before reading `takeCompletedTurns()`.
  void emitTurn({required String source, required String target}) {
    _send({'type': 'input_audio_buffer.speech_started'});
    _send({'type': 'session.input_transcript.delta', 'delta': source});
    _send({'type': 'session.output_transcript.delta', 'delta': target});
    _send({'type': 'input_audio_buffer.speech_stopped'});
  }

  Future<void> close() async {
    await _socket?.close();
    await _server.close(force: true);
  }
}

void main() {
  late _MockRealtimeServer server;

  setUp(() async {
    server = await _MockRealtimeServer.start();
    OpenAiRealtimeService.endpointOverride = server.url;
  });

  tearDown(() async {
    OpenAiRealtimeService.endpointOverride =
        'wss://api.openai.com/v1/realtime/translations';
    await server.close();
  });

  test('connects, authenticates and reports ready', () async {
    final service = OpenAiRealtimeService();
    addTearDown(service.dispose);

    await service.connect(apiKey: 'test-key', targetLanguage: 'en');
    // Give the socket a moment to open.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(service.isConnected, isTrue);
    expect(service.state, 'ready');
  });

  test('reports a completed turn with source and target text', () async {
    final service = OpenAiRealtimeService();
    addTearDown(service.dispose);

    await service.connect(apiKey: 'test-key', targetLanguage: 'en');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    server.emitTurn(source: 'Guten Tag', target: 'Good day');
    // The service finalises a turn 900 ms after speech_stopped.
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final turns = service.takeCompletedTurns();
    expect(turns, hasLength(1));
    expect(turns.single.sourceText, 'Guten Tag');
    expect(turns.single.targetText, 'Good day');
  });

  test('accumulates transcript deltas across a turn', () async {
    final service = OpenAiRealtimeService();
    addTearDown(service.dispose);

    await service.connect(apiKey: 'test-key', targetLanguage: 'en');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    server.emitTurn(source: 'Guten Tag, wie geht es dir?',
        target: 'Good day, how are you?');
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(service.inputTranscript, contains('Guten Tag'));
    expect(service.outputTranscript, contains('Good day'));
  });

  test('counts speech starts so barge-in can react', () async {
    final service = OpenAiRealtimeService();
    addTearDown(service.dispose);

    await service.connect(apiKey: 'test-key', targetLanguage: 'en');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final before = service.speechStarts;
    server.emitTurn(source: 'Hallo', target: 'Hello');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(service.speechStarts, greaterThan(before));
  });

  test('sends captured audio as a base64 append message', () async {
    final service = OpenAiRealtimeService();
    addTearDown(service.dispose);

    await service.connect(apiKey: 'test-key', targetLanguage: 'en');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    service.sendPcm16(Uint8List.fromList(List<int>.filled(320, 0)));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // The realtime endpoint takes audio as a JSON append with base64 payload,
    // not as a binary frame.
    final appends = server.received
        .where((m) => m != '<binary>')
        .map((m) => jsonDecode(m) as Map<String, dynamic>)
        .where((m) => m['type'] == 'session.input_audio_buffer.append')
        .toList();
    expect(appends, isNotEmpty);
    expect(appends.first['audio'], isA<String>());
    expect((appends.first['audio'] as String).isNotEmpty, isTrue);
  });

  test('refuses to connect without a key', () async {
    final service = OpenAiRealtimeService();
    addTearDown(service.dispose);

    expect(
      () => service.connect(apiKey: '  ', targetLanguage: 'en'),
      throwsArgumentError,
    );
  });
}
