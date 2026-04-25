import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/settings/presentation/providers/settings_provider.dart';
import 'package:novaapp/features/settings/presentation/blocked_contacts_screen.dart';

class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Privacidad', style: TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        children: [
          _buildSectionHeader('MENSAJERÍA'),
          SwitchListTile(
            title: const Text('Confirmaciones de lectura', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Permite que otros vean cuándo has leído sus mensajes.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            value: settings.readReceipts,
            activeThumbColor: NovaColors.primary,
            onChanged: (val) => notifier.setReadReceipts(val),
          ),
          SwitchListTile(
            title: const Text('Indicador de escritura', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Permite que otros vean cuándo estás escribiendo.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            value: settings.typingIndicator,
            activeThumbColor: NovaColors.primary,
            onChanged: (val) => notifier.setTypingIndicator(val),
          ),
          
          const Divider(color: Colors.white10),
          _buildSectionHeader('CONTACTOS'),
          ListTile(
            title: const Text('Contactos bloqueados', style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BlockedContactsScreen()),
              );
            },
          ),
          
          const Divider(color: Colors.white10),
          _buildSectionHeader('ESTADÍSTICAS'),
          SwitchListTile(
            title: const Text('Enviar estadísticas de uso', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Ayúdanos a mejorar NovaApp enviando datos anónimos.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            value: false,
            onChanged: (val) {},
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: NovaColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
