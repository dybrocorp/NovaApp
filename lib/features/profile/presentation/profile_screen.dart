import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);
    final nameAsync = ref.watch(nameProvider);
    final avatarAsync = ref.watch(avatarProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: const Text('Mi Perfil'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: identityAsync.when(
            data: (id) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Threema-Style Identity Card Section
                Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: isDark ? [] : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      )
                    ],
                  ),
                  child: Column(
                    children: [
                      // Avatar with Purple Circle Background
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: avatarAsync.value != null
                            ? ClipOval(child: Image.file(File(avatarAsync.value!), fit: BoxFit.cover))
                            : const Icon(Icons.lock_person, size: 50, color: Colors.white),
                      ),
                      const SizedBox(height: 24),
                      
                      // Nickname
                      Text(
                        nameAsync.value ?? 'Usuario Nova',
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      
                      const Text(
                        'ID DE NOVAAPP',
                        style: TextStyle(color: Colors.grey, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      
                      // The Monospaced ID
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: colorScheme.onSurface.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          id ?? '--------',
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      
                      // Integrated QR
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: QrImageView(
                          data: id ?? '',
                          version: QrVersions.auto,
                          size: 160.0,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 48),
                
                // Action Buttons
                ElevatedButton.icon(
                  onPressed: () {
                    if (id != null) {
                      Share.share(
                        '¡Conéctate conmigo en NovaApp! Mi ID único es: $id\n\nNovaApp: Privacidad total, seguridad absoluta.',
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.share),
                  label: const Text('COMPARTIR MI ID'),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('CERRAR', style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.5))),
                ),
              ],
            ),
            loading: () => const CircularProgressIndicator(),
            error: (e, s) => Text('Error: $e'),
          ),
        ),
      ),
    );
  }
}
