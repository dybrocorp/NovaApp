import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/features/settings/presentation/providers/settings_provider.dart';

class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: const Text('Apariencia', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        children: [
          _buildSectionHeader(context, 'TEMA'),
          _buildThemeOption(context, notifier, 'Claro (Blanco/Morado)', ThemeMode.light, settings.themeMode),
          _buildThemeOption(context, notifier, 'Oscuro', ThemeMode.dark, settings.themeMode),
          
          const Divider(height: 32, indent: 16, endIndent: 16, color: Colors.white10),
          
          _buildSectionHeader(context, 'ESTILO DE BURBUJA'),
          SizedBox(
            height: 180,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                _buildBubblePreview(context, notifier, 'Estándar', BubbleStyle.standard, settings.bubbleStyle),
                _buildBubblePreview(context, notifier, 'Geométrico', BubbleStyle.geometric, settings.bubbleStyle),
                _buildBubblePreview(context, notifier, 'Minimalista', BubbleStyle.minimal, settings.bubbleStyle),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Selecciona un estilo para cambiar la apariencia de las burbujas en todos los chats instantáneamente.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildThemeOption(BuildContext context, SettingsNotifier notifier, String title, ThemeMode mode, ThemeMode current) {
    final isSelected = current == mode;
    return ListTile(
      title: Text(title),
      trailing: isSelected 
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => notifier.setThemeMode(mode),
    );
  }

  Widget _buildBubblePreview(BuildContext context, SettingsNotifier notifier, String title, BubbleStyle style, BubbleStyle current) {
    final isSelected = style == current;
    final primary = Theme.of(context).colorScheme.primary;

    return GestureDetector(
      onTap: () => notifier.setBubbleStyle(style),
      child: Container(
        width: 130,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: isSelected ? Border.all(color: primary, width: 2) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Dummy Bubble Preview
            Container(
              width: 80,
              height: 40,
              decoration: BoxDecoration(
                color: primary,
                borderRadius: _getBorderRadius(style, true),
              ),
              child: const Icon(Icons.abc, color: Colors.white30, size: 24),
            ),
            const SizedBox(height: 12),
            Container(
              width: 80,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.2),
                borderRadius: _getBorderRadius(style, false),
              ),
              child: const Icon(Icons.abc, color: Colors.grey, size: 24),
            ),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(
              fontSize: 12, 
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? primary : null,
            )),
          ],
        ),
      ),
    );
  }

  BorderRadius _getBorderRadius(BubbleStyle style, bool isMe) {
    switch (style) {
      case BubbleStyle.standard:
        return BorderRadius.circular(16);
      case BubbleStyle.geometric:
        return BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 0),
          bottomRight: Radius.circular(isMe ? 0 : 16),
        );
      case BubbleStyle.minimal:
        return BorderRadius.circular(4);
    }
  }
}
