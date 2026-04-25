import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:secure_application/secure_application.dart';
import 'core/theme/nova_theme.dart';
import 'core/services/supabase_service.dart';
import 'features/auth/presentation/onboarding_screen.dart';
import 'features/settings/logic/security_manager.dart';
import 'features/settings/presentation/providers/security_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();
  runApp(
    const ProviderScope(
      child: NovaApp(),
    ),
  );
}

class NovaApp extends ConsumerWidget {
  const NovaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Initialize security settings
    ref.watch(securityInitProvider);
    final screenSecurity = ref.watch(screenSecurityProvider);

    return SecureApplication(
      nativeRemoveDelay: 100,
      onNeedUnlock: (secure) async {
        secure?.lock();
        return null;
      },
      child: MaterialApp(
        title: 'NovaApp',
        debugShowCheckedModeBanner: false,
        theme: NovaTheme.darkTheme,
        builder: (context, child) {
          return SecureGate(
            lockedBuilder: (context, secureNotifier) => Container(color: Colors.black),
            child: SecurityManager(
              child: Builder(
                builder: (context) {
                  final secureNotifier = SecureApplicationProvider.of(context);
                  if (screenSecurity) {
                    secureNotifier?.secure();
                  } else {
                    secureNotifier?.open();
                  }
                  return child!;
                },
              ),
            ),
          );
        },
        home: const OnboardingScreen(),
      ),
    );
  }
}
