import 'package:flutter/material.dart';

/// Neutral surfaces with one indigo accent.
class AppTheme {
  static ThemeData light() => _build(
    brightness: Brightness.light,
    // A mid-grey backdrop so the white tiles and list stand out from it.
    background: const Color(0xFFE3E7ED),
    surface: Colors.white,
    surfaceLow: const Color(0xFFE8EBF0), // Claude's bubbles
    surfaceHigh: const Color(0xFFF0F2F5), // column headers
    border: const Color(0xFFC4CBD6),
    text: const Color(0xFF0B1220),
    textMuted: const Color(0xFF475467),
    accent: const Color(0xFF6D28D9), // the purple of the app icon
    accentSoft: const Color(0xFFEDE4FF), // your bubbles, open-thread highlight
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    background: const Color(0xFF0E1015),
    surface: const Color(0xFF161920),
    surfaceLow: const Color(0xFF1F232C),
    surfaceHigh: const Color(0xFF1A1D25),
    border: const Color(0xFF2A2F3A),
    text: const Color(0xFFE6E8EC),
    textMuted: const Color(0xFF98A2B3),
    accent: const Color(0xFF8B8CF6),
    accentSoft: const Color(0xFF272A55),
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color surfaceLow,
    required Color surfaceHigh,
    required Color border,
    required Color text,
    required Color textMuted,
    required Color accent,
    required Color accentSoft,
  }) {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
      primary: accent,
      onPrimary: brightness == Brightness.light ? Colors.white : const Color(0xFF0E1015),
      primaryContainer: accentSoft,
      onPrimaryContainer: text,
      surface: surface,
      onSurface: text,
      surfaceContainer: surfaceLow,
      surfaceContainerHigh: surfaceHigh,
      outline: textMuted,
      outlineVariant: border,
      tertiary: const Color(0xFFDC6803),
    );
    final textTheme = Typography.material2021(platform: TargetPlatform.macOS).black
        .apply(bodyColor: text, displayColor: text)
        .copyWith(
          bodySmall: TextStyle(color: textMuted, fontSize: 12),
          labelSmall: TextStyle(color: textMuted, fontSize: 11, fontWeight: FontWeight.w500),
        );
    final base = textTheme.bodyMedium!;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: border)),
        titleTextStyle: base.copyWith(color: text, fontSize: 17, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border),
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: border),
        selectedColor: accentSoft,
        backgroundColor: surface,
        labelStyle: base.copyWith(color: text, fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: base.copyWith(color: textMuted),
      ),
      iconTheme: IconThemeData(color: textMuted),
      textTheme: textTheme,
    );
  }

  /// Marks threads with messages you haven't seen.
  static Color unread(Brightness b) => b == Brightness.light ? const Color(0xFF8A5100) : const Color(0xFFE3B341);
}
