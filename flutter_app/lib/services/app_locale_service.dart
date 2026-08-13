import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';
import '../l10n/locale_resolution.dart';

/// Tracks the user's explicit UI language choice.
///
/// Set the moment the user taps a flag on the welcome screen's language
/// splash, and from then on drives every screen's locale directly — not just
/// a one-time default. Persisted so it survives app restarts. Null until the
/// user has ever picked a flag, in which case MaterialApp falls back to
/// resolving the device locale via [resolveAppLocale].
class AppLocaleService extends ChangeNotifier {
  static const _key = 'snail_ui_locale';

  Locale? _locale;
  Locale? get locale => _locale;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved != null) _locale = Locale(saved);
    } catch (_) {
      // Best-effort: without a saved choice the app falls back to
      // device-locale resolution, which is a safe default.
    }
  }

  /// Applies a language code the user picked (e.g. by tapping a flag) as the
  /// app's UI language, immediately and for every subsequent screen.
  /// Unsupported languages fall back to English rather than silently
  /// keeping whatever locale was active before.
  Future<void> setLocale(String languageCode) async {
    final resolved = resolveAppLocale(
        Locale(languageCode), AppLocalizations.supportedLocales);
    if (_locale != resolved) {
      // Notify before persisting so the UI switches on this frame; the
      // SharedPreferences write is disk I/O and must not gate that.
      _locale = resolved;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, resolved.languageCode);
    } catch (_) {
      // Best-effort: the in-memory choice still applies for this session.
    }
  }
}
