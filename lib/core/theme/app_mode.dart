import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppMode {
  personal,
  corporate,
}

class AppModeConfig {
  final AppMode mode;
  final String displayName;
  final String description;
  final ThemeData theme;
  final bool enableAdvancedFeatures;
  final bool requireAuthentication;
  final bool enableEncryption;
  final int maxFileSize;
  final int maxGroupSize;
  final bool allowExternalSharing;

  AppModeConfig({
    required this.mode,
    required this.displayName,
    required this.description,
    required this.theme,
    this.enableAdvancedFeatures = true,
    this.requireAuthentication = true,
    this.enableEncryption = true,
    this.maxFileSize = 100, // MB
    this.maxGroupSize = 500,
    this.allowExternalSharing = true,
  });

  static AppModeConfig get personalMode => AppModeConfig(
    mode: AppMode.personal,
    displayName: 'Modo Personal',
    description: 'Diseñado para uso personal con todas las funciones',
    theme: _buildPersonalTheme(),
    enableAdvancedFeatures: true,
    requireAuthentication: false,
    enableEncryption: true,
    maxFileSize: 100,
    maxGroupSize: 500,
    allowExternalSharing: true,
  );

  static AppModeConfig get corporateMode => AppModeConfig(
    mode: AppMode.corporate,
    displayName: 'Modo Corporativo',
    description: 'Diseñado para empresas con seguridad avanzada',
    theme: _buildCorporateTheme(),
    enableAdvancedFeatures: true,
    requireAuthentication: true,
    enableEncryption: true,
    maxFileSize: 500,
    maxGroupSize: 2000,
    allowExternalSharing: false,
  );

  static ThemeData _buildPersonalTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF9B51E0),
        secondary: Color(0xFF56CCF2),
        surface: Color(0xFF1C1C1E),
        surfaceContainer: Color(0xFF0F0F0F),
        error: Color(0xFFEB5757),
      ),
      scaffoldBackgroundColor: const Color(0xFF0F0F0F),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0F0F0F),
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1C1C1E),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF9B51E0),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF9B51E0),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1C1C1E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
    );
  }

  static ThemeData _buildCorporateTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF10362D),
        secondary: Color(0xFF1E5C4E),
        surface: Color(0xFF1A1A1A),
        surfaceContainer: Color(0xFF0A0A0A),
        error: Color(0xFFC62828),
      ),
      scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0A0A0A),
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A1A1A),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF10362D),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF1E5C4E),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1A1A1A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Color(0xFF10362D)),
        ),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
    );
  }
}

class AppModeNotifier extends StateNotifier<AppModeConfig> {
  AppModeNotifier() : super(AppModeConfig.personalMode) {
    _loadMode();
  }

  Future<void> _loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    final modeString = prefs.getString('app_mode') ?? 'personal';
    final mode = AppMode.values.firstWhere(
      (m) => m.name == modeString,
      orElse: () => AppMode.personal,
    );
    state = mode == AppMode.personal ? AppModeConfig.personalMode : AppModeConfig.corporateMode;
  }

  Future<void> setMode(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_mode', mode.name);
    state = mode == AppMode.personal ? AppModeConfig.personalMode : AppModeConfig.corporateMode;
  }

  Future<void> toggleMode() async {
    final newMode = state.mode == AppMode.personal ? AppMode.corporate : AppMode.personal;
    await setMode(newMode);
  }
}

final appModeProvider = StateNotifierProvider<AppModeNotifier, AppModeConfig>((ref) {
  return AppModeNotifier();
});
