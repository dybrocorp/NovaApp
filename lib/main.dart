import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:secure_application/secure_application.dart';
import 'package:firebase_core/firebase_core.dart';
import 'core/theme/app_mode.dart';
import 'core/services/supabase_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/logger_service.dart';
import 'features/auth/presentation/onboarding_screen.dart';
import 'features/settings/logic/security_manager.dart';
import 'features/settings/presentation/providers/security_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    LoggerService.warning('Environment file not found or error loading', error: e, tag: 'main');
  }
  
  try {
    await Firebase.initializeApp();
  } catch (e) {
    LoggerService.warning('Firebase initialization failed (push notifications disabled)', error: e, tag: 'main');
  }

  try {
    await SupabaseService.initialize();
  } catch (e) {
    LoggerService.warning('Supabase initialization failed (optional)', error: e, tag: 'main');
  }

  try {
    final notifService = NotificationService();
    await notifService.initialize();
    if (notifService.fcmToken != null) {
      await SupabaseService().saveFcmToken(notifService.fcmToken!);
    }
  } catch (e) {
    LoggerService.warning('Notification service initialization failed', error: e, tag: 'main');
  }
  
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
    final appMode = ref.watch(appModeProvider);

    return SecureApplication(
      nativeRemoveDelay: 100,
      onNeedUnlock: (secure) async {
        secure?.lock();
        return null;
      },
      child: MaterialApp(
        title: 'NovaApp',
        debugShowCheckedModeBanner: false,
        theme: appMode.theme,
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
