import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snail/l10n/app_localizations.dart';
import 'package:snail/l10n/locale_resolution.dart';
import 'package:snail/services/app_locale_service.dart';

void main() {
  group('resolveAppLocale', () {
    test('matches a supported device language exactly', () {
      expect(
        resolveAppLocale(const Locale('de'), AppLocalizations.supportedLocales),
        const Locale('de'),
      );
      expect(
        resolveAppLocale(const Locale('uk'), AppLocalizations.supportedLocales),
        const Locale('uk'),
      );
    });

    test('matches by language code, ignoring region', () {
      // A German-Austrian or English-UK device locale must still resolve to
      // the shipped translation, not fall through to the English default.
      expect(
        resolveAppLocale(
            const Locale('de', 'AT'), AppLocalizations.supportedLocales),
        const Locale('de'),
      );
      expect(
        resolveAppLocale(
            const Locale('en', 'GB'), AppLocalizations.supportedLocales),
        const Locale('en'),
      );
    });

    test('falls back to English, not German, for an unsupported language',
        () {
      // Portuguese is not one of the shipped translations. Falling back to
      // German (the ARB template language) here would make the app look
      // German-only to a Portuguese speaker instead of a neutral default.
      expect(
        resolveAppLocale(const Locale('pt'), AppLocalizations.supportedLocales),
        const Locale('en'),
      );
      expect(
        resolveAppLocale(const Locale('ru'), AppLocalizations.supportedLocales),
        const Locale('en'),
      );
    });

    test('falls back to English when the device reports no locale', () {
      expect(
        resolveAppLocale(null, AppLocalizations.supportedLocales),
        const Locale('en'),
      );
    });
  });

  group('AppLocalizations end to end', () {
    Future<AppLocalizations> load(String languageCode) =>
        AppLocalizations.delegate.load(Locale(languageCode));

    test('German is the ARB template and matches the source strings', () async {
      final l10n = await load('de');
      expect(l10n.commonCancel, 'Abbrechen');
      expect(l10n.homeStartSession, 'Session starten');
    });

    test('English translations are present and distinct from German',
        () async {
      final l10n = await load('en');
      expect(l10n.commonCancel, 'Cancel');
      expect(l10n.homeStartSession, 'Start session');
    });

    test('Ukrainian translations are present and distinct from German',
        () async {
      final l10n = await load('uk');
      expect(l10n.commonCancel, 'Скасувати');
      expect(l10n.homeStartSession, 'Почати сесію');
    });

    test('a placeholder message substitutes its argument in every locale',
        () async {
      final de = await load('de');
      final en = await load('en');
      final uk = await load('uk');
      expect(de.sessionRoomCode('snail-ABCD'), contains('snail-ABCD'));
      expect(en.sessionRoomCode('snail-ABCD'), contains('snail-ABCD'));
      expect(uk.sessionRoomCode('snail-ABCD'), contains('snail-ABCD'));
    });
  });

  group('AppLocaleService', () {
    test('has no explicit locale before the user ever picks a flag', () {
      SharedPreferences.setMockInitialValues({});
      expect(AppLocaleService().locale, isNull);
    });

    test('setLocale applies a supported language immediately', () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppLocaleService();
      var notified = false;
      service.addListener(() => notified = true);

      await service.setLocale('uk');

      expect(notified, isTrue,
          reason: 'MaterialApp must rebuild on this frame, not after the '
              'SharedPreferences write completes');
      expect(service.locale, const Locale('uk'));
    });

    test('setLocale falls back to English for an unsupported language',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppLocaleService();

      await service.setLocale('pt');

      expect(service.locale, const Locale('en'));
    });

    test('the picked locale persists across a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final first = AppLocaleService();
      await first.setLocale('uk');

      // Simulate the next app launch: a fresh service loading from the same
      // (mocked) persisted storage.
      final second = AppLocaleService();
      await second.load();

      expect(second.locale, const Locale('uk'));
    });

    test('load leaves locale null when nothing was ever picked', () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppLocaleService();
      await service.load();
      expect(service.locale, isNull);
    });
  });
}
