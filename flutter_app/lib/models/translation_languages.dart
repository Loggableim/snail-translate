/// Languages Snail can translate between, shared by every screen so the
/// quick translator, the session screen and the settings can never drift
/// apart again.
///
/// `native` is the endonym shown in dropdowns; `label` is the same name
/// with the uppercase code appended for compact chip rows.
const translationLanguages = <({String code, String native})>[
  (code: 'de', native: 'Deutsch'),
  (code: 'en', native: 'English'),
  (code: 'fr', native: 'Français'),
  (code: 'es', native: 'Español'),
  (code: 'it', native: 'Italiano'),
  (code: 'ja', native: '日本語'),
  (code: 'ko', native: '한국어'),
  (code: 'zh', native: '中文'),
  (code: 'uk', native: 'Українська'),
  (code: 'ar', native: 'العربية'),
  (code: 'pt', native: 'Português'),
  (code: 'ru', native: 'Русский'),
  (code: 'nl', native: 'Nederlands'),
  (code: 'tr', native: 'Türkçe'),
  (code: 'hi', native: 'हिन्दी'),
  (code: 'vi', native: 'Tiếng Việt'),
  (code: 'pl', native: 'Polski'),
  (code: 'sv', native: 'Svenska'),
];

/// Native name for a code, falling back to the bare uppercase code so a
/// persisted value outside this list still renders a readable label.
String languageLabel(String code) {
  for (final language in translationLanguages) {
    if (language.code == code) return language.native;
  }
  return code.toUpperCase();
}