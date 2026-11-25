import 'package:flutter/material.dart';

/// BuildCrew design tokens.
///
/// Design intent: the worker app is used outdoors, in sunlight, on cheap screens, by people who
/// may not read comfortably. So: high contrast, warm "site" palette, colour that *means*
/// something (amber = waiting, green = money/yes, grey = closed), 56–64dp touch targets,
/// and numerals that are huge and tabular.
class BC {
  // Brand
  static const brand = Color(0xFFEA580C); // safety-vest orange
  static const brandDark = Color(0xFFC2410C);
  static const brandSoft = Color(0xFFFFEDD5);

  // Neutrals (warm, like paper and cement rather than cold blue-grey)
  static const ink = Color(0xFF1C1917);
  static const inkSoft = Color(0xFF57534E);
  static const inkFaint = Color(0xFFA8A29E);
  static const line = Color(0xFFE7E5E4);
  static const bg = Color(0xFFFAF8F5);
  static const card = Colors.white;

  // Semantic — readable without reading
  static const money = Color(0xFF15803D);
  static const moneySoft = Color(0xFFDCFCE7);
  static const pending = Color(0xFFF59E0B);
  static const pendingSoft = Color(0xFFFEF3C7);
  static const closed = Color(0xFF78716C);
  static const closedSoft = Color(0xFFF5F5F4);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF2563EB);
  static const infoSoft = Color(0xFFDBEAFE);

  // Spacing / shape
  static const r = 16.0;
  static const rLg = 24.0;
  static const tap = 56.0; // minimum touch target
  static const tapLg = 64.0; // primary actions in the worker app

  static const tabular = [FontFeature.tabularFigures()];
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: BC.brand,
    primary: BC.brand,
    onPrimary: Colors.white,
    surface: BC.card,
    onSurface: BC.ink,
    error: BC.danger,
  );
  // Indic scripts render from Android's system Noto fonts; we only tune size/weight/height.
  // Taller line-height keeps Devanagari/Bengali matras and Tamil/Malayalam glyphs from clipping.
  const base = TextTheme(
    displayLarge: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, height: 1.1, letterSpacing: -1, fontFeatures: BC.tabular),
    displayMedium: TextStyle(fontSize: 36, fontWeight: FontWeight.w800, height: 1.15, fontFeatures: BC.tabular),
    headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.3),
    headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.35),
    titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, height: 1.4),
    titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.4),
    bodyLarge: TextStyle(fontSize: 17, height: 1.5),
    bodyMedium: TextStyle(fontSize: 15, height: 1.5),
    labelLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3),
    labelMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3),
  );
  final text = base.apply(bodyColor: BC.ink, displayColor: BC.ink);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: BC.bg,
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: BC.bg,
      foregroundColor: BC.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: BC.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: BC.brand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: BC.line,
        minimumSize: const Size.fromHeight(BC.tapLg),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BC.ink,
        minimumSize: const Size.fromHeight(BC.tap),
        side: const BorderSide(color: BC.line, width: 1.5),
        textStyle: text.titleMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.r)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(BC.r), borderSide: const BorderSide(color: BC.line, width: 1.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(BC.r), borderSide: const BorderSide(color: BC.line, width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(BC.r), borderSide: const BorderSide(color: BC.brand, width: 2)),
    ),
    cardTheme: CardThemeData(
      color: BC.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.rLg), side: const BorderSide(color: BC.line)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 76,
      backgroundColor: Colors.white,
      indicatorColor: BC.brandSoft,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 13,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
            color: s.contains(WidgetState.selected) ? BC.ink : BC.inkSoft,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 28,
            color: s.contains(WidgetState.selected) ? BC.brandDark : BC.inkSoft,
          )),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
