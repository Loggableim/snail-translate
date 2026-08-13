import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'l10n/app_localizations.dart';
import 'l10n/locale_resolution.dart';
import 'services/app_locale_service.dart';
import 'services/session_service.dart';
import 'services/audio_service.dart';
import 'services/user_identity_service.dart';
import 'services/contact_service.dart';
import 'services/provider_config_service.dart';
import 'services/gemini_live_service.dart';
import 'services/openai_realtime_service.dart';
import 'services/fish_audio_realtime_service.dart';
import 'services/transcript_history.dart';
import 'services/audio_policy.dart';
import 'services/error_logger.dart';
import 'services/app_share_service.dart';
import 'theme/app_theme.dart';
import 'screens/welcome_screen.dart';
import 'screens/home_screen.dart';
import 'screens/qr_host_screen.dart';
import 'screens/join_screen.dart';
import 'screens/session_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/identity_qr_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/provider_settings_screen.dart';
import 'screens/history_screen.dart';
import 'screens/error_log_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/standalone_screen.dart';
import 'screens/app_share_screen.dart';
import 'screens/profile_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sessionService = SessionService();
  await sessionService.init();
  final identityService = UserIdentityService();
  await identityService.init();
  if (identityService.identity != null) {
    sessionService.setIdentityId(identityService.identity!.userId);
  }
  sessionService.setIdentityService(identityService);
  final contactService = ContactService();
  await contactService.init();
  final providerConfigService = ProviderConfigService();
  await providerConfigService.init();
  final history = TranscriptHistory();
  await history.load();
  final audioPolicy = AudioPolicy();
  await audioPolicy.load();
  final appLocale = AppLocaleService();
  await appLocale.load();
  runApp(SnailApp(
      sessionService: sessionService,
      identityService: identityService,
      contactService: contactService,
      providerConfigService: providerConfigService,
      history: history,
      audioPolicy: audioPolicy,
      appLocale: appLocale));
}

class SnailApp extends StatelessWidget {
  final SessionService sessionService;
  final UserIdentityService identityService;
  final ContactService contactService;
  final ProviderConfigService providerConfigService;
  final TranscriptHistory history;
  final AudioPolicy audioPolicy;
  final AppLocaleService appLocale;

  const SnailApp(
      {super.key,
      required this.sessionService,
      required this.identityService,
      required this.contactService,
      required this.providerConfigService,
      required this.history,
      required this.audioPolicy,
      required this.appLocale});

  @override
  Widget build(BuildContext context) {
    final app = MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: sessionService),
        ChangeNotifierProvider.value(value: identityService),
        ChangeNotifierProvider.value(value: contactService),
        ChangeNotifierProvider.value(value: providerConfigService),
        ChangeNotifierProvider(create: (_) => GeminiLiveService()),
        ChangeNotifierProvider(create: (_) => OpenAiRealtimeService()),
        ChangeNotifierProvider(create: (_) => FishAudioRealtimeService()),
        ChangeNotifierProvider(create: (_) => AudioService()),
        ChangeNotifierProvider.value(value: ErrorLogger.I),
        ChangeNotifierProvider.value(value: history),
        ChangeNotifierProvider.value(value: audioPolicy),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AppShareService()),
        ChangeNotifierProvider.value(value: appLocale),
      ],
      child: Consumer2<ThemeProvider, AppLocaleService>(
        builder: (context, theme, locale, _) {
          return MaterialApp(
            title: 'Snail',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: theme.themeMode,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            // Before the user has ever picked a flag, locale.locale is null
            // and MaterialApp falls back to resolving the device locale via
            // localeResolutionCallback. Once AppLocaleService holds a value
            // (set the moment a flag is tapped on the welcome screen), it
            // takes over directly and MaterialApp no longer consults device
            // locale at all — the explicit choice sticks across every
            // screen and app restart.
            locale: locale.locale,
            localeResolutionCallback: resolveAppLocale,
            initialRoute: '/welcome',
            routes: {
              '/welcome': (_) => const WelcomeScreen(),
              '/': (_) => const HomeScreen(),
              '/qr-host': (_) => const QrHostScreen(),
              '/join': (_) => const JoinScreen(),
              '/session': (_) => const SessionScreen(),
              '/settings': (_) => const SettingsScreen(),
              '/my-qr': (_) => const IdentityQrScreen(),
              '/chat': (_) => const ChatScreen(),
              '/provider-settings': (_) => const ProviderSettingsScreen(),
              '/history': (_) => const HistoryScreen(),
              '/error-log': (_) => const ErrorLogScreen(),
              '/contacts': (_) => const ContactsScreen(),
              '/standalone': (_) => const StandaloneScreen(),
              '/app-share': (_) => const AppShareScreen(),
              '/profile': (_) => const ProfileScreen(),
            },
          );
        },
      ),
    );
    return app;
  }
}
