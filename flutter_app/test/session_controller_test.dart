import 'package:flutter_test/flutter_test.dart';
import 'package:snail/controllers/session_controller.dart';

void main() {
  test('orchestrates connect, language change, peer loss, and end', () async {
    final events = <String>[];
    final controller = SessionController(
      initialTargetLanguage: 'en',
      connect: (generation) async => events.add('connect:$generation'),
      disconnect: () async => events.add('disconnect'),
      setTargetLanguage: (language) async => events.add('language:$language'),
    );

    await controller.start();
    expect(controller.state, SessionControllerState.connected);
    await controller.changeLanguage('de');
    expect(controller.targetLanguage, 'de');
    expect(controller.state, SessionControllerState.connected);
    await controller.peerLost();
    expect(controller.state, SessionControllerState.reconnecting);
    await controller.end();
    expect(controller.state, SessionControllerState.ended);
    expect(events, <String>[
      'connect:1',
      'disconnect',
      'language:de',
      'connect:2',
      'disconnect',
      'disconnect',
    ]);
    controller.dispose();
  });
}
