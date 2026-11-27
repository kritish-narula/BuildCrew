import 'package:flutter/material.dart';

/// BuildCrew design tokens.
///
/// Design intent: calm, modern Indian consumer app (clean cards, one accent colour, clear
/// status colours) that is still readable outdoors on cheap screens by people who may not
/// read comfortably. So: high contrast, warm paper-like neutrals, colour that *means*
/// something (amber = waiting, green = money/yes, grey = closed), generous touch targets,
/// and tabular numerals for money only.
class BC {
  // Brand — used sparingly: primary button, selected states, small accents.
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
  static const pendingInk = Color(0xFF92400E); // readable text on pendingSoft
  static const closed = Color(0xFF78716C);
  static const closedSoft = Color(0xFFF5F5F4);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF2563EB);
  static const infoSoft = Color(0xFFDBEAFE);

  // Shape
  static const rSm = 12.0;
  static const r = 16.0;
  static const rMd = 20.0; // cards
  static const rLg = 24.0;

  // Touch targets / button heights
  static const tap = 56.0; // worker-critical actions (Quote price, Check in, I'm on my way)
  static const tapLg = 56.0; // kept for compatibility; no longer larger than [tap]
  static const btn = 52.0; // primary
  static const btnSm = 48.0; // secondary / outlined
  static const btnXs = 40.0; // compact / inline

  // Spacing
  static const pad = 16.0;
  static const padLg = 20.0;

  static const fontFamily = 'Mukta';

  /// Tabular figures — use ONLY on numbers / money so digits line up.
  static const tabular = [FontFeature.tabularFigures()];

  /// THE money text style (one weight, tabular figures): every rupee amount uses it via `MoneyText`
  /// (widgets/common.dart). Sizes: s 15 · m 18 · l 24 · xl 34.
  static TextStyle moneyText(double size, [Color? color]) =>
      TextStyle(fontSize: size, fontWeight: FontWeight.w700, height: 1.25, fontFeatures: tabular, color: color);

  /// Soft shadow for raised cards (very light; borders do most of the work).
  static const softShadow = [BoxShadow(color: Color(0x0F1C1917), blurRadius: 12, offset: Offset(0, 4))];

  // Small shared text styles for places without a BuildContext (inherit family from theme).
  static const caption = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.4, color: inkSoft);
  static const subtle = TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.45, color: inkSoft);
}

/// Shortcut: `context.tt.titleLarge`.
extension BCContext on BuildContext {
  TextTheme get tt => Theme.of(this).textTheme;
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

  // Calm scale. Line-height >= 1.35 everywhere so Devanagari matras never clip.
  // Mukta covers Latin + Devanagari; other Indic scripts fall back to Android's Noto fonts.
  const base = TextTheme(
    displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1.25, fontFeatures: BC.tabular), // money
    displayMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, height: 1.25, fontFeatures: BC.tabular),
    displaySmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.3, fontFeatures: BC.tabular),
    headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.35),
    headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.35),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.4),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4),
    titleSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.4),
    bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.5),
    bodyMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, height: 1.45),
    bodySmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, height: 1.4),
    labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.35),
    labelMedium: TextStyle(fontFamily: BC.fontFamily, fontSize: 13, fontWeight: FontWeight.w500, height: 1.35),
    labelSmall: TextStyle(fontFamily: BC.fontFamily, fontSize: 12, fontWeight: FontWeight.w500, height: 1.35),
  );
  final text = base.apply(bodyColor: BC.ink, displayColor: BC.ink, fontFamily: BC.fontFamily);

  const buttonLabel = TextStyle(fontFamily: BC.fontFamily, fontSize: 16, fontWeight: FontWeight.w700, height: 1.3);
  const buttonLabelSecondary = TextStyle(fontFamily: BC.fontFamily, fontSize: 15, fontWeight: FontWeight.w600, height: 1.3);
  final btnShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  const btnPad = EdgeInsets.symmetric(horizontal: 20);

  OutlineInputBorder border(Color c, [double w = 1.2]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));

  return ThemeData(
    useMaterial3: true,
    fontFamily: BC.fontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: BC.bg,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: BC.bg,
      foregroundColor: BC.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: text.titleLarge!.copyWith(color: BC.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: BC.brand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: BC.line,
        disabledForegroundColor: BC.inkFaint,
        minimumSize: const Size.fromHeight(BC.btn),
        padding: btnPad,
        textStyle: buttonLabel,
        shape: btnShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BC.ink,
        minimumSize: const Size.fromHeight(BC.btnSm),
        padding: btnPad,
        side: const BorderSide(color: BC.line, width: 1.5),
        textStyle: buttonLabelSecondary,
        shape: btnShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: BC.brandDark,
        minimumSize: const Size(0, BC.btnXs),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: buttonLabelSecondary,
        shape: btnShape,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: BC.brandSoft,
        selectedForegroundColor: BC.brandDark,
        foregroundColor: BC.inkSoft,
        side: const BorderSide(color: BC.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      labelStyle: const TextStyle(fontFamily: BC.fontFamily, color: BC.inkSoft, fontSize: 15),
      hintStyle: const TextStyle(fontFamily: BC.fontFamily, color: BC.inkFaint),
      border: border(BC.line),
      enabledBorder: border(BC.line),
      focusedBorder: border(BC.brand, 1.8),
      errorBorder: border(BC.danger),
      focusedErrorBorder: border(BC.danger, 1.8),
    ),
    cardTheme: CardThemeData(
      color: BC.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.rMd), side: const BorderSide(color: BC.line)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white,
      selectedColor: BC.brandSoft,
      side: const BorderSide(color: BC.line),
      shape: const StadiumBorder(),
      labelStyle: const TextStyle(fontFamily: BC.fontFamily, fontSize: 14, fontWeight: FontWeight.w600, color: BC.ink),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      titleTextStyle: TextStyle(fontFamily: BC.fontFamily, fontSize: 16, fontWeight: FontWeight.w600, color: BC.ink, height: 1.35),
      subtitleTextStyle: TextStyle(fontFamily: BC.fontFamily, fontSize: 14, fontWeight: FontWeight.w400, color: BC.inkSoft, height: 1.4),
    ),
    dividerTheme: const DividerThemeData(color: BC.line, thickness: 1, space: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BC.rLg)),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyLarge!.copyWith(color: BC.inkSoft),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(BC.rLg))),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: BC.brand),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : BC.inkFaint),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? BC.money : BC.line),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: BC.brandSoft,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: BC.fontFamily,
            fontSize: 13,
            height: 1.3,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? BC.ink : BC.inkSoft,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 26,
            color: s.contains(WidgetState.selected) ? BC.brandDark : BC.inkSoft,
          )),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: BC.ink,
      contentTextStyle: text.bodyLarge!.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
