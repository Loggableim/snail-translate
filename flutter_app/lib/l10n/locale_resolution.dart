import 'package:flutter/widgets.dart';

/// Picks the app locale for a [requested] locale — either the device-reported
/// locale at first launch, or a language code the user explicitly picked
/// (e.g. by tapping a flag).
///
/// Matches by language code only (ignoring region/script), so e.g. `de_AT`
/// still resolves to the `de` translation. Falls back to English, not German
/// (the ARB template language), for any language Snail does not ship a
/// translation for — an unsupported locale should not silently look like a
/// German-only app to everyone else.
Locale resolveAppLocale(Locale? requested, Iterable<Locale> supportedLocales) {
  if (requested != null) {
    for (final supported in supportedLocales) {
      if (supported.languageCode == requested.languageCode) {
        return supported;
      }
    }
  }
  return const Locale('en');
}
