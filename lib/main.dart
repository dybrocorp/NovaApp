import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/nova_theme.dart';
import 'features/auth/presentation/onboarding_screen.dart';

void main() {
  runApp(
    const ProviderScope(
      child: NovaApp(),
    ),
  );
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NovaApp',
      debugShowCheckedModeBanner: false,
      theme: NovaTheme.darkTheme,
      home: const OnboardingScreen(),
    );
  }
}
