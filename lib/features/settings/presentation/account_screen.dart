import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/auth/presentation/onboarding_screen.dart';
import 'package:novaapp/features/settings/presentation/app_lock_settings_screen.dart';
import 'package:novaapp/features/settings/presentation/backup_id_screen.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Cuenta', style: TextStyle(color: Colors.white, fontSize: 20)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        children: [
          // Section: Seguridad
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Text(
              'Seguridad',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          ListTile(
            title: const Text('Bloqueo de la aplicación', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              'Usa PIN, patrón o biometría para acceder a la app.',
              style: TextStyle(color: Colors.white54),
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white24),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AppLockSettingsScreen()),
              );
            },
          ),
          const SizedBox(height: 8),
          const Divider(color: Colors.white10),
          const SizedBox(height: 8),

          // Section: Cuenta
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Text(
              'Cuenta',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          ListTile(
            title: const Text('Exportar ID de Nova', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              'Crea una copia de seguridad de tu identidad.',
              style: TextStyle(color: Colors.white54),
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BackupIdScreen()),
              );
            },
          ),
          ListTile(
            title: const Text('Transferir cuenta', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              'Transfiere tu cuenta a un dispositivo Android nuevo.',
              style: TextStyle(color: Colors.white54),
            ),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Datos de tu cuenta', style: TextStyle(color: Colors.white)),
            onTap: () {},
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text(
              'Eliminar cuenta',
              style: TextStyle(color: Color(0xFFE57373)),
            ),
            onTap: () => _showDeleteAccountDialog(context, ref),
          ),
        ],
      ),
    );
  }

  void _showDeleteAccountDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '¿Eliminar cuenta?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Esta acción eliminará permanentemente todos tus datos: tu ID de Nova, nombre, foto de perfil, chats y contactos.\n\nEsta acción NO se puede deshacer.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // Delete all stored data
              final repo = ref.read(identityRepositoryProvider);
              await repo.deleteAllData();
              // Navigate to onboarding and clear the entire navigation stack
              if (context.mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                  (route) => false,
                );
              }
            },
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Color(0xFFE57373), fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
