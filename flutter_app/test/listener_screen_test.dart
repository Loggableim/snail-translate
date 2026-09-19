import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/models/session.dart';
import 'package:snail/screens/listener_screen.dart';
import 'package:snail/services/audio_service.dart';
import 'package:snail/services/session_service.dart';
import 'package:snail/theme/app_theme.dart';

/// A session service that already holds a listener session, so the screen can
/// connect without a Worker.
class _ListenerSessionService extends SessionService {
  _ListenerSessionService(this._session);
  final Session _session;

  @override
  Session? get currentSession => _session;
}

Session _guideSession() => Session(
      roomId: 'snail-ABCD2345',
      sessionToken: 'token',
      relayUrl: 'ws://127.0.0.1:1/ws?room=snail-ABCD2345',
      sourceLang: 'de',
      targetLang: 'en',
      tier: 'free',
      role: 'listener',
      quotaRemaining: 0,
      mode: 'guide',
      listenerLanguages: const ['de', 'en', 'fr'],
    );

Widget _wrap(Widget child, {SessionService? sessionService}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SessionService>(
          create: (_) => sessionService ?? _ListenerSessionService(_guideSession())),
      ChangeNotifierProvider(create: (_) => AudioService()),
    ],
    child: MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.darkTheme,
      home: child,
    ),
  );
}

void main() {
  setUp(() {
    // flutter_tts talks to a platform channel that does not exist in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (call) async {
        if (call.method == 'isLanguageAvailable') return true;
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  testWidgets('listener screen offers only the languages the room serves',
      (tester) async {
    await tester.pumpWidget(_wrap(const ListenerScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Zuhör-Modus'), findsOneWidget);
    expect(find.text('Deine Sprache'), findsOneWidget);
    // The device language is German and the room offers it, so it is picked.
    expect(find.text('Deutsch'), findsWidgets);
    expect(find.text('Warte auf die erste Übersetzung …'), findsOneWidget);
  });

  testWidgets('listener screen filters subtitles to the chosen language',
      (tester) async {
    await tester.pumpWidget(_wrap(const ListenerScreen()));
    await tester.pumpAndSettle();

    final state = tester.state<State<ListenerScreen>>(find.byType(ListenerScreen));
    // Drive the relay callback the way the WebSocket would.
    final relay = Provider.of<AudioService>(
        tester.element(find.byType(ListenerScreen)),
        listen: false);
    relay.onSubtitle?.call({
      'messageId': 'a',
      'text': 'Guten Tag',
      'sourceLang': 'de',
      'targetLang': 'de',
      'timestamp': 1,
    });
    relay.onSubtitle?.call({
      'messageId': 'b',
      'text': 'Good day',
      'sourceLang': 'de',
      'targetLang': 'en',
      'timestamp': 2,
    });
    await tester.pumpAndSettle();

    // German is selected: only the German line is visible.
    expect(find.text('Guten Tag'), findsOneWidget);
    expect(find.text('Good day'), findsNothing);

    // Switch to English and the other line appears.
    await tester.tap(find.text('Deutsch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(find.text('Good day'), findsOneWidget);
    expect(find.text('Guten Tag'), findsNothing);
    expect(state.mounted, isTrue);
  });

  testWidgets('listener screen shows a waiting state without subtitles',
      (tester) async {
    await tester.pumpWidget(_wrap(const ListenerScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Warte auf die erste Übersetzung …'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
  });
}
