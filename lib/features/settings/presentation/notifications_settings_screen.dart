import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/features/settings/presentation/providers/settings_provider.dart';

class NotificationsSettingsScreen extends ConsumerWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notificaciones', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        children: [
          _buildSectionHeader(context, 'GENERAL'),
          SwitchListTile(
            title: const Text('Habilitar notificaciones'),
            value: settings.notificationsEnabled,
            onChanged: (val) => notifier.setNotificationsEnabled(val),
          ),
          
          if (settings.notificationsEnabled) ...[
            const Divider(height: 1),
            _buildSectionHeader(context, 'MENSAJES'),
            SwitchListTile(
              title: const Text('Mostrar previsualización'),
              subtitle: const Text('Mostrar remitente y mensaje en la notificación.', style: TextStyle(fontSize: 12)),
              value: settings.previewEnabled,
              onChanged: (val) => notifier.setPreviewEnabled(val),
            ),
            ListTile(
              title: const Text('Sonido de notificación'),
              subtitle: Text('Predeterminado', style: TextStyle(color: colorScheme.primary, fontSize: 12)),
              trailing: const Icon(Icons.volume_up, size: 20),
              onTap: () {},
            ),
          ],
          
          const Divider(height: 32, indent: 16, endIndent: 16),
          _buildSectionHeader(context, 'MODO NO MOLESTAR'),
          SwitchListTile(
            title: const Text('Habilitar programación'),
            subtitle: const Text('Silenciar notificaciones durante un horario específico.', style: TextStyle(fontSize: 12)),
            value: settings.dndEnabled,
            onChanged: (val) => notifier.setDndEnabled(val),
          ),
          
          if (settings.dndEnabled) ...[
            ListTile(
              title: const Text('Desde'),
              subtitle: const Text('Hora de inicio del silencio', style: TextStyle(fontSize: 11)),
              trailing: Text(settings.dndStartTime, style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold)),
              onTap: () => _pickTime(context, notifier, true, settings.dndStartTime, settings.dndEndTime),
            ),
            ListTile(
              title: const Text('Hasta'),
              subtitle: const Text('Hora de fin del silencio', style: TextStyle(fontSize: 11)),
              trailing: Text(settings.dndEndTime, style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold)),
              onTap: () => _pickTime(context, notifier, false, settings.dndStartTime, settings.dndEndTime),
            ),
          ],
          
          const SizedBox(height: 48),
          const Center(
            child: Text(
              'Las notificaciones se reactivarán automáticamente\nfinalizado el horario de silencio.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTime(BuildContext context, SettingsNotifier notifier, bool isStart, String start, String end) async {
    final currentStr = isStart ? start : end;
    final parts = currentStr.split(':');
    final initialTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));

    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              surface: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1C1C1E) : Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final newTime = "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}";
      if (isStart) {
        notifier.setDndRange(newTime, end);
      } else {
        notifier.setDndRange(start, newTime);
      }
    }
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
}
