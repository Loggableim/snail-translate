import 'package:flutter/material.dart';

class ThemeProvider extends ChangeNotifier {
  // Snail is primarily used in conversations and travel situations where a
  // low-glare interface is more comfortable. Users can still switch to light.
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == ThemeMode.dark;

  void toggle() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  void setTheme(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }
}

class AppTheme {
  /// Shared brand typography. Noto Sans is deliberately broad in language
  /// coverage, so UI, web copy and Ukrainian conversation content stay clear.
  static const fontFamily = 'Noto Sans';

  // Snail brand: ink (the shell background), lilac (the snail) and mint (the
  // conversation bubble). The darker/lighter variants preserve readable text.
  static const ink = Color(0xFF0C102C);
  static const lilac = Color(0xFFC18AFF);
  static const deepLilac = Color(0xFF6F36A7);
  static const mint = Color(0xFF9DE8CB);
  static const deepMint = Color(0xFF167C68);
  static const cloud = Color(0xFFF8F6FF);

  static const _lightColors = ColorScheme.light(
    primary: deepLilac,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFEBD9FF),
    onPrimaryContainer: Color(0xFF2C0A4C),
    secondary: deepMint,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFC7F4E3),
    onSecondaryContainer: Color(0xFF003D32),
    surface: Colors.white,
    onSurface: Color(0xFF17152B),
    surfaceContainerHighest: Color(0xFFECEAF3),
    outline: Color(0xFF797286),
    error: Color(0xFFB3261E),
  );

  static const _darkColors = ColorScheme.dark(
    primary: lilac,
    onPrimary: Color(0xFF2A0A49),
    primaryContainer: Color(0xFF482064),
    onPrimaryContainer: Color(0xFFF0E1FF),
    secondary: mint,
    onSecondary: Color(0xFF003D32),
    secondaryContainer: Color(0xFF104F43),
    onSecondaryContainer: Color(0xFFC7F4E3),
    surface: Color(0xFF11152F),
    onSurface: Color(0xFFF5F1FF),
    surfaceContainerHighest: Color(0xFF202540),
    outline: Color(0xFF958EA3),
    error: Color(0xFFFFB4AB),
  );

  static final lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: fontFamily,
    colorScheme: _lightColors,
    scaffoldBackgroundColor: cloud,
    appBarTheme: const AppBarTheme(
        centerTitle: false, elevation: 0, backgroundColor: Colors.transparent),
    cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: _lightColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _lightColors.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none)),
  );

  static final darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: fontFamily,
    colorScheme: _darkColors,
    scaffoldBackgroundColor: ink,
    appBarTheme: const AppBarTheme(
        centerTitle: false, elevation: 0, backgroundColor: Colors.transparent),
    cardTheme: CardThemeData(
        elevation: 0,
        color: _darkColors.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _darkColors.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none)),
  );
}
