import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI source files do not reintroduce known raw status literals', () {
    const sourceFiles = [
      'lib/screens/session_screen.dart',
      'lib/screens/standalone_screen.dart',
      'lib/screens/app_share_screen.dart',
      'lib/screens/history_screen.dart',
      'lib/services/app_share_service.dart',
      'lib/services/session_service.dart',
      'lib/services/translation_service.dart',
    ];
    const forbidden = [
      'Noise-Gate:',
      'Mikrofon:',
      'Ungültiger Raumcode',
      'Network error:',
      'Übertragung läuft',
      'Tunnel getrennt',
      'Unbegrenzt',
      'Unbekannt',
    ];

    for (final path in sourceFiles) {
      final source = File(path).readAsStringSync();
      for (final literal in forbidden) {
        expect(source, isNot(contains(literal)), reason: '$path contains $literal');
      }
    }
  });

  test('all supported ARB locales contain the shared status keys', () {
    final arbFiles = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.arb'))
        .toList();
    expect(arbFiles.length, 9);
    for (final file in arbFiles) {
      final source = file.readAsStringSync();
      for (final key in [
        'sessionNoiseGateLevel',
        'sessionMicrophoneLevel',
        'paywallUnlimited',
        'commonUnknown',
      ]) {
        expect(source, contains('"$key"'), reason: '${file.path} lacks $key');
      }
    }
  });
}
