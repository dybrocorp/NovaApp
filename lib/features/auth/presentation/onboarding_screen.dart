import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/permission_service.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/auth/presentation/identity_generation_screen.dart';
import 'package:novaapp/features/auth/presentation/recovery_screen.dart';
import 'package:novaapp/features/chat/presentation/chat_list_screen.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Check if user already has an identity → skip to chat list
    final identityAsync = ref.watch(identityProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return identityAsync.when(
      data: (id) {
        // If user already has a name saved, they completed setup → go to chats
        final nameAsync = ref.watch(nameProvider);
        return nameAsync.when(
          data: (name) {
            if (id != null && name != null && name.isNotEmpty) {
              // Already registered, go directly to chat list
              WidgetsBinding.instance.addPostFrameCallback((_) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const ChatListScreen()),
                  (route) => false,
                );
              });
              return Scaffold(
                backgroundColor: isDark ? Colors.black : Colors.white,
                body: const Center(child: CircularProgressIndicator()),
              );
            }
            return _buildOnboardingUI(context, ref);
          },
          loading: () => Scaffold(
            backgroundColor: isDark ? Colors.black : Colors.white,
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => _buildOnboardingUI(context, ref),
        );
      },
      loading: () => Scaffold(
        backgroundColor: isDark ? Colors.black : Colors.white,
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => _buildOnboardingUI(context, ref),
    );
  }

  Widget _buildOnboardingUI(BuildContext context, WidgetRef ref) {
    final screenHeight = MediaQuery.of(context).size.height;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 40),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: screenHeight - 120),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SizedBox(height: 20),
                  Hero(
                    tag: 'logo',
                    child: Image.asset(
                      'assets/onboarding.png',
                      height: screenHeight * 0.35,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Column(
                    children: [
                      Text(
                        'Privacidad sin límites.\nSeguridad total.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Sin número de teléfono. Sin correo.\nTu identidad es completamente anónima.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'NovaApp genera un ID único para ti.\nNo se requiere información personal.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          await PermissionService.requestAllPermissions();
                          if (context.mounted) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const IdentityGenerationScreen()),
                            );
                          }
                        },
                        child: const Text('CREAR MI IDENTIDAD', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const RecoveryScreen()),
                          );
                        },
                        child: Text(
                          'Ya tengo un ID de Nova',
                          style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
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
