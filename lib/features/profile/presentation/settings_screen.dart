import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/profile/presentation/profile_screen.dart';
import 'package:novaapp/features/settings/presentation/app_lock_settings_screen.dart';
import 'package:novaapp/features/settings/presentation/appearance_settings_screen.dart';
import 'package:novaapp/features/settings/presentation/privacy_settings_screen.dart';
import 'package:novaapp/features/settings/presentation/notifications_settings_screen.dart';
import 'package:novaapp/features/settings/presentation/chat_settings_screen.dart';
import 'package:novaapp/features/settings/presentation/help_screen.dart';
import 'package:novaapp/features/settings/presentation/about_screen.dart';
import 'package:novaapp/features/settings/presentation/donation_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      final repo = ref.read(identityRepositoryProvider);
      await repo.saveAvatarPath(pickedFile.path);
      ref.invalidate(avatarProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto de perfil actualizada')),
      );
    }
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: NovaColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white),
              title: const Text('Tomar foto', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.white),
              title: const Text('Elegir de galería', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditNameDialog(String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NovaColors.surface,
        title: const Text('Editar nombre', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Tu nombre',
            hintStyle: TextStyle(color: Colors.white30),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: NovaColors.primary)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                await ref.read(identityRepositoryProvider).saveName(newName);
                ref.invalidate(nameProvider);
                if (!context.mounted) return;
                Navigator.pop(context);
              }
            },
            child: const Text('GUARDAR', style: TextStyle(color: NovaColors.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nameAsync = ref.watch(nameProvider);
    final identityAsync = ref.watch(identityProvider);
    final avatarAsync = ref.watch(avatarProvider);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: const Text('Ajustes', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        children: [
          // Profile Header
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                // Avatar with Camera Overlay
                GestureDetector(
                  onTap: _showImagePickerOptions,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: colorScheme.surface,
                        backgroundImage: avatarAsync.value != null 
                          ? FileImage(File(avatarAsync.value!)) 
                          : null,
                        child: avatarAsync.value == null 
                          ? Icon(Icons.person, size: 40, color: colorScheme.onSurface.withValues(alpha: 0.5)) 
                          : null,
                      ),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: isDark ? Colors.black : Colors.white, width: 2),
                        ),
                        child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showEditNameDialog(nameAsync.value ?? ''),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                nameAsync.value ?? 'Usuario Nova',
                                style: TextStyle(
                                  color: colorScheme.onSurface, 
                                  fontSize: 20, 
                                  fontWeight: FontWeight.bold
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.edit, size: 16, color: colorScheme.onSurface.withValues(alpha: 0.3)),
                          ],
                        ),
                        Text(
                          identityAsync.value ?? 'NOVA ID',
                          style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.5), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.qr_code, color: colorScheme.primary),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const ProfileScreen()));
                  },
                ),
              ],
            ),
          ),
          
          _buildCategoryHeader(context, 'PERFIL'),
          _buildMenuItem(context, Icons.person_outline, 'Ajustes de perfil', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const ProfileScreen()));
          }),
          _buildMenuItem(context, Icons.qr_code_scanner, 'Escanear ID', onTap: () {
            // Scanner navigation handled by scanner screen which is accessible from chats
          }),

          _buildCategoryHeader(context, 'PRIVACIDAD'),
          _buildMenuItem(context, Icons.security, 'Privacidad', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const PrivacySettingsScreen()));
          }),
          _buildMenuItem(context, Icons.block, 'Contactos bloqueados'),

          _buildCategoryHeader(context, 'APARIENCIA'),
          _buildMenuItem(context, Icons.brightness_medium_outlined, 'Diseño', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const AppearanceSettingsScreen()));
          }),
          _buildMenuItem(context, Icons.chat_bubble_outline, 'Chats', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const ChatSettingsScreen()));
          }),
          _buildMenuItem(context, Icons.notifications_none, 'Notificaciones', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const NotificationsSettingsScreen()));
          }),

          _buildCategoryHeader(context, 'SEGURIDAD'),
          _buildMenuItem(context, Icons.lock_outline, 'Bloqueo de la aplicación', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const AppLockSettingsScreen()));
          }),
          _buildMenuItem(context, Icons.history, 'Copia de seguridad (Safe)'),

          _buildCategoryHeader(context, 'COMUNIDAD Y OTROS'),
          _buildMenuItem(context, Icons.favorite_border, 'Apoyar a NovaApp (Donar)', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const DonationScreen()));
          }),
          _buildMenuItem(context, Icons.help_outline, 'Ayuda', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const HelpScreen()));
          }),
          _buildMenuItem(context, Icons.info_outline, 'Acerca de NovaApp v2.0', onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const AboutScreen()));
          }),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _buildCategoryHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _buildMenuItem(BuildContext context, IconData icon, String title, {VoidCallback? onTap}) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: colorScheme.onSurface.withValues(alpha: 0.7), size: 22),
      title: Text(title, style: TextStyle(color: colorScheme.onSurface, fontSize: 16)),
      trailing: Icon(Icons.chevron_right, color: colorScheme.onSurface.withValues(alpha: 0.2), size: 20),
      onTap: onTap ?? () {},
    );
  }
}
