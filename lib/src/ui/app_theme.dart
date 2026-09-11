import 'package:flutter/material.dart';

abstract final class AppColors {
  static const primary = Color(0xFF6C57E5);
  static const primarySoft = Color(0xFFF0EDFF);
  static const canvas = Color(0xFFF4F3F8);
  static const surface = Color(0xFFFFFFFF);
  static const sidebar = Color(0xFFF8F7FB);
  static const line = Color(0xFFE9E7EF);
  static const text = Color(0xFF25232C);
  static const muted = Color(0xFF898593);
  static const success = Color(0xFF2BB673);
  static const warning = Color(0xFFF0A124);
  static const danger = Color(0xFFE35A6B);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.light,
    surface: AppColors.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamilyFallback: const [
      'Microsoft YaHei UI',
      'PingFang SC',
      'Noto Sans CJK SC',
    ],
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.text, fontSize: 13),
      bodySmall: TextStyle(color: AppColors.muted, fontSize: 11),
      titleMedium: TextStyle(
        color: AppColors.text,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: const Color(0xFFF8F8FB),
      hintStyle: const TextStyle(color: AppColors.muted, fontSize: 12),
      prefixIconColor: AppColors.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.3),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF26242C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    dividerColor: AppColors.line,
  );
}
