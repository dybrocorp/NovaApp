import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nova_colors.dart';

class NovaTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: NovaColors.primary,
      scaffoldBackgroundColor: NovaColors.background,
      colorScheme: ColorScheme.dark(
        primary: NovaColors.primary,
        secondary: NovaColors.primaryLight,
        surface: NovaColors.surface,
        surfaceContainer: NovaColors.background,
        error: NovaColors.error,
        onPrimary: Colors.white,
        onSurface: NovaColors.textPrimary,
      ),
      textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: GoogleFonts.outfit(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: NovaColors.textPrimary,
        ),
        bodyLarge: GoogleFonts.outfit(
          fontSize: 16,
          color: NovaColors.textPrimary,
        ),
        bodyMedium: GoogleFonts.outfit(
          fontSize: 14,
          color: NovaColors.textSecondary,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: NovaColors.background,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: NovaColors.textPrimary,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: NovaColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: NovaColors.primary,
        foregroundColor: Colors.white,
      ),
    );
  }
}
