import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/core/services/permission_service.dart';
import 'package:novaapp/features/auth/presentation/phone_auth_screen.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: NovaColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: screenHeight - 120),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SizedBox(height: 20),
                  // Central Illustration
                  Image.asset(
                    'assets/onboarding.png',
                    height: screenHeight * 0.35,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 32),
                  // Welcome Text
                  Column(
                    children: const [
                      Text(
                        'Privacidad sin límites.\nSeguridad total.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          height: 1.2,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'El refugio seguro para tus conversaciones.\nConfianza absoluta en cada mensaje.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: NovaColors.textSecondary,
                        ),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'NovaApp es una organización de mensajería segura\nTérminos y Política de privacidad',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: NovaColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  // Action Buttons
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF333333),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: () async {
                          await PermissionService.requestAllPermissions();
                          if (context.mounted) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const PhoneAuthScreen()),
                            );
                          }
                        },
                        child: const Text('CONTINUAR'),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Función de restauración próximamente')),
                          );
                        },
                        child: const Text(
                          'Restaurar o transferir cuenta',
                          style: TextStyle(color: NovaColors.primary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
