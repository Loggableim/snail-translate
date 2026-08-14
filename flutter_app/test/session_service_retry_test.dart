import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:snail/services/session_service.dart';

class _DelayedClient extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return http.StreamedResponse(Stream.value(<int>[]), 200);
  }
}

void main() {
  test('does not repeat a timed-out room join POST', () async {
    final client = _DelayedClient();
    final service = SessionService(
      httpClient: client,
      requestTimeout: const Duration(milliseconds: 1),
    );
    addTearDown(service.dispose);

    expect(await service.joinRoom('snail-ABCD2345'), isNull);
    expect(client.requests, 1);
  });
}
