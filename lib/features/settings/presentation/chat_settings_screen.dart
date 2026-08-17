import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/settings/presentation/providers/settings_provider.dart';
import 'package:novaapp/features/settings/data/models.dart';

class ChatSettingsScreen extends ConsumerWidget {
  const ChatSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Chats', style: TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        children: [
          _buildSectionHeader('ESCRITURA'),
          SwitchListTile(
            title: const Text('Enviar con Enter', style: TextStyle(color: Colors.white)),
            value: settings.enterSends,
            activeThumbColor: NovaColors.primary,
            onChanged: (val) => notifier.setEnterSends(val),
          ),
          
          const Divider(color: Colors.white10),
          _buildSectionHeader('APARIENCIA DEL CHAT'),
          ListTile(
            title: const Text('Tamaño de fuente', style: TextStyle(color: Colors.white)),
            subtitle: Text('${settings.fontSize.toInt()} px', style: const TextStyle(color: NovaColors.primary, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () => _showFontSizeDialog(context, settings, notifier),
          ),
          ListTile(
            title: const Text('Estilo de burbuja', style: TextStyle(color: Colors.white)),
            subtitle: Text(_getBubbleStyleName(settings.bubbleStyle), style: const TextStyle(color: NovaColors.primary, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () => _showBubbleStyleDialog(context, settings, notifier),
          ),
          
          const Divider(color: Colors.white10),
          _buildSectionHeader('MULTIMEDIA'),
          SwitchListTile(
            title: const Text('Guardar en galería', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Guardar automáticamente archivos entrantes.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            value: settings.autoSaveMedia,
            activeThumbColor: NovaColors.primary,
            onChanged: (val) => notifier.setAutoSaveMedia(val),
          ),
        ],
      ),
    );
  }

  void _showFontSizeDialog(BuildContext context, SettingsState settings, SettingsNotifier notifier) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NovaColors.surface,
        title: const Text('Tamaño de fuente', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFontSizeOption(dialogContext, notifier, 'Pequeño', 14.0, settings.fontSize),
            _buildFontSizeOption(dialogContext, notifier, 'Normal', 16.0, settings.fontSize),
            _buildFontSizeOption(dialogContext, notifier, 'Grande', 18.0, settings.fontSize),
            _buildFontSizeOption(dialogContext, notifier, 'Muy grande', 20.0, settings.fontSize),
          ],
        ),
      ),
    );
  }

  Widget _buildFontSizeOption(BuildContext dialogContext, SettingsNotifier notifier, String label, double size, double current) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: current == size ? const Icon(Icons.check, color: NovaColors.primary) : null,
      onTap: () {
        notifier.setFontSize(size);
        Navigator.pop(dialogContext);
      },
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

  void _showBubbleStyleDialog(BuildContext context, SettingsState settings, SettingsNotifier notifier) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NovaColors.surface,
        title: const Text('Estilo de burbuja', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBubbleStyleOption(dialogContext, notifier, 'Estándar', BubbleStyle.standard, settings.bubbleStyle),
            _buildBubbleStyleOption(dialogContext, notifier, 'Geométrico', BubbleStyle.geometric, settings.bubbleStyle),
            _buildBubbleStyleOption(dialogContext, notifier, 'Minimalista', BubbleStyle.minimal, settings.bubbleStyle),
          ],
        ),
      ),
    );
  }

  Widget _buildBubbleStyleOption(BuildContext dialogContext, SettingsNotifier notifier, String label, BubbleStyle style, BubbleStyle current) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: current == style ? const Icon(Icons.check, color: NovaColors.primary) : null,
      onTap: () {
        notifier.setBubbleStyle(style);
        Navigator.pop(dialogContext);
      },
    );
  }

  String _getBubbleStyleName(BubbleStyle style) {
    switch (style) {
      case BubbleStyle.standard:
        return 'Estándar';
      case BubbleStyle.geometric:
        return 'Geométrico';
      case BubbleStyle.minimal:
        return 'Minimalista';
    }
  }
}
