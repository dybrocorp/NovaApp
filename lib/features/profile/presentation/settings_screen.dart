import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nameAsync = ref.watch(nameProvider);
    final phoneAsync = ref.watch(phoneProvider);
    final avatarAsync = ref.watch(avatarProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Ajustes'),
      ),
      body: ListView(
        children: [
          // Profile Header
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: const Color(0xFF2C2C2E),
                  backgroundImage: avatarAsync.value != null 
                    ? FileImage(File(avatarAsync.value!)) 
                    : null,
                  child: avatarAsync.value == null 
                    ? const Icon(Icons.person, size: 40, color: Colors.white70) 
                    : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nameAsync.value ?? 'Usuario Nova',
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        phoneAsync.value ?? '+00 000 000 000',
                        style: const TextStyle(color: NovaColors.textTertiary, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10),
          _buildMenuItem(Icons.person_outline, 'Cuenta'),
          _buildMenuItem(Icons.devices, 'Dispositivos vinculados'),
          _buildMenuItem(Icons.favorite_border, 'Haz una donación a NovaApp'), // Renamed from Signal
          const Divider(color: Colors.white10, height: 32),
          _buildMenuItem(Icons.brightness_medium_outlined, 'Apariencia'),
          _buildMenuItem(Icons.chat_outlined, 'Chats'),
          _buildMenuItem(Icons.filter_none, 'Historias'),
          _buildMenuItem(Icons.notifications_none, 'Notificaciones'),
          _buildMenuItem(Icons.lock_outline, 'Privacidad'),
          _buildMenuItem(Icons.history, 'Copias de seguridad'),
          _buildMenuItem(Icons.pie_chart_outline, 'Datos y almacenamiento'),
          const Divider(color: Colors.white10, height: 32),
          _buildMenuItem(Icons.credit_card_outlined, 'Pagos'),
          const Divider(color: Colors.white10, height: 32),
          _buildMenuItem(Icons.help_outline, 'Ayuda'),
          _buildMenuItem(Icons.mail_outline, '¡Invita a otras personas!'),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildMenuItem(IconData icon, String title) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
      onTap: () {},
    );
  }
}
