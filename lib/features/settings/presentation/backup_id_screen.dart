import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:qr_flutter/qr_flutter.dart';

class BackupIdScreen extends ConsumerWidget {
  const BackupIdScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Copia de seguridad del ID', style: TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: identityAsync.when(
        data: (id) => _buildContent(context, id ?? 'NO-ID'),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildContent(BuildContext context, String id) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          const Text(
            'Tu ID de NovaApp es tu identidad única. Si pierdes el acceso a este dispositivo y no tienes una copia de seguridad, PERDERÁS tu ID y todos tus contactos.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 32),
          
          // QR Code Section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: QrImageView(
              data: id,
              version: QrVersions.auto,
              size: 200.0,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            id,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 48),

          // Backup Actions
          _buildBackupOption(
            Icons.file_download_outlined,
            'Exportar a archivo',
            'Crea un archivo de respaldo protegido por contraseña.',
            () {},
          ),
          const SizedBox(height: 16),
          _buildBackupOption(
            Icons.cloud_upload_outlined,
            'Threema Safe',
            'Copia de seguridad automática y anónima en la nube.',
            () {},
            isHighlight: true,
          ),
          const SizedBox(height: 16),
          _buildBackupOption(
            Icons.print_outlined,
            'Imprimir copia de seguridad',
            'Genera un PDF con tu ID y código de recuperación.',
            () {},
          ),
        ],
      ),
    );
  }

  Widget _buildBackupOption(IconData icon, String title, String subtitle, VoidCallback onTap, {bool isHighlight = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isHighlight ? NovaColors.primary.withValues(alpha: 0.1) : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isHighlight ? NovaColors.primary : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: isHighlight ? NovaColors.primary : Colors.white70, size: 28),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isHighlight ? NovaColors.primary : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}
