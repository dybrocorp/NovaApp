import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/app_mode.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

class AppModeSettingsScreen extends ConsumerWidget {
  const AppModeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appMode = ref.watch(appModeProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Modo de Aplicación', style: TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Elige el modo que mejor se adapte a tus necesidades:',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 24),
          _buildModeCard(
            context,
            ref,
            AppModeConfig.personalMode,
            appMode.mode == AppMode.personal,
            Icons.person,
          ),
          const SizedBox(height: 16),
          _buildModeCard(
            context,
            ref,
            AppModeConfig.corporateMode,
            appMode.mode == AppMode.corporate,
            Icons.business,
          ),
          const SizedBox(height: 24),
          _buildCurrentModeInfo(context, appMode),
        ],
      ),
    );
  }

  Widget _buildModeCard(
    BuildContext context,
    WidgetRef ref,
    AppModeConfig config,
    bool isSelected,
    IconData icon,
  ) {
    return GestureDetector(
      onTap: () async {
        await ref.read(appModeProvider.notifier).setMode(config.mode);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Modo cambiado a ${config.displayName}'),
              backgroundColor: config.theme.colorScheme.primary,
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: config.theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? config.theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: config.theme.colorScheme.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: config.theme.colorScheme.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.displayName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        config.description,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(
                    Icons.check_circle,
                    color: config.theme.colorScheme.primary,
                    size: 28,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _buildFeatureRow('Autenticación requerida', config.requireAuthentication),
            _buildFeatureRow('Encriptación activada', config.enableEncryption),
            _buildFeatureRow('Funciones avanzadas', config.enableAdvancedFeatures),
            _buildFeatureRow('Tamaño máximo archivo', '${config.maxFileSize} MB'),
            _buildFeatureRow('Tamaño máximo grupo', '${config.maxGroupSize}'),
            _buildFeatureRow('Compartir externo', config.allowExternalSharing),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureRow(String label, dynamic value) {
    final displayValue = value is bool ? (value ? 'Sí' : 'No') : value.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Text(
            displayValue,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentModeInfo(BuildContext context, AppModeConfig appMode) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: appMode.theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: appMode.theme.colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: appMode.theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Modo actual: ${appMode.displayName}',
                style: TextStyle(
                  color: appMode.theme.colorScheme.primary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            appMode.description,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
