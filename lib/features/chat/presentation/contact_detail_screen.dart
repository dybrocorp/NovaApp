import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/core/services/moderation_service.dart';

import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/presentation/call_screen.dart';

class ContactDetailScreen extends ConsumerWidget {
  final ChatContact contact;

  const ContactDetailScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Avatar & Name Section
            Center(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: const Color(0xFF2C2C2E),
                    child: Text(
                      contact.name[0],
                      style: const TextStyle(fontSize: 48, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    contact.name,
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  _buildVerificationRow(contact.verificationLevel),
                ],
              ),
            ),
            const SizedBox(height: 48),

            // Info Card
            _buildInfoCard(context),

            const SizedBox(height: 32),

            // Actions Section
            _buildActionTile(Icons.chat_outlined, 'Enviar mensaje', () => Navigator.pop(context)),
            _buildActionTile(Icons.call_outlined, 'Llamada de voz', () => _openCall(context, isVideo: false)),
            _buildActionTile(Icons.videocam_outlined, 'Video llamada', () => _openCall(context, isVideo: true)),
            _buildActionTile(Icons.share_outlined, 'Compartir contacto', () {}),
            
            const Divider(color: Colors.white10, height: 48, indent: 16, endIndent: 16),

            _buildActionTile(Icons.flag_outlined, 'Reportar usuario', () => _showReportDialog(context, ref), color: Colors.orange),
            _buildActionTile(Icons.block, 'Bloquear contacto', () => _showBlockDialog(context, ref), color: Colors.red),
            _buildActionTile(Icons.delete_outline, 'Eliminar historial de chat', () {}, color: Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationRow(VerificationLevel level) {
    int count = 1;
    Color color = Colors.red;
    String label = 'Nivel de seguridad 1';

    if (level == VerificationLevel.level2) {
      count = 2;
      color = Colors.orange;
      label = 'Nivel de seguridad 2';
    } else if (level == VerificationLevel.level3) {
      count = 3;
      color = Colors.green;
      label = 'Nivel de seguridad 3';
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(count, (index) => Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          )),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }

  void _openCall(BuildContext context, {required bool isVideo}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CallScreen(
          contactId: contact.id,
          contactName: contact.name,
          isVideo: isVideo,
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          _buildInfoRow('ID de NovaApp', contact.id, isHighlight: true),
          const Divider(color: Colors.white10, height: 32),
          _buildInfoRow('Clave pública', contact.publicKey != null && contact.publicKey!.isNotEmpty
              ? 'X25519: ${contact.publicKey!.substring(0, contact.publicKey!.length > 16 ? 16 : contact.publicKey!.length)}...'
              : 'No disponible'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isHighlight = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: isHighlight ? NovaColors.primaryLight : Colors.white,
            fontSize: 18,
            fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
            fontFamily: isHighlight ? 'monospace' : null,
          ),
        ),
      ],
    );
  }

  Widget _buildActionTile(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white}) {
    return ListTile(
      leading: Icon(icon, color: color.withValues(alpha: 0.8)),
      title: Text(label, style: TextStyle(color: color, fontSize: 16)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
    );
  }

  void _showReportDialog(BuildContext context, WidgetRef ref) {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('Reportar usuario', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: reasonController,
          decoration: const InputDecoration(
            hintText: 'Razón del reporte...',
            hintStyle: TextStyle(color: Colors.white54),
          ),
          style: const TextStyle(color: Colors.white),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              if (reasonController.text.isNotEmpty) {
                try {
                  final identityRepo = ref.read(identityRepositoryProvider);
                  final myNovaId = await identityRepo.getId();
                  final moderationService = ref.read(moderationServiceProvider);
                  
                  await moderationService.reportUser(
                    reporterId: myNovaId ?? '',
                    reportedId: contact.id,
                    reason: reasonController.text,
                  );
                  
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Usuario reportado exitosamente')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error al reportar: $e')),
                    );
                  }
                }
              }
            },
            child: const Text('Reportar', style: TextStyle(color: NovaColors.primaryLight)),
          ),
        ],
      ),
    );
  }

  void _showBlockDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('Bloquear contacto', style: TextStyle(color: Colors.white)),
        content: Text('¿Estás seguro de que quieres bloquear a ${contact.name}?', style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              try {
                final identityRepo = ref.read(identityRepositoryProvider);
                final myNovaId = await identityRepo.getId();
                final moderationService = ref.read(moderationServiceProvider);
                
                await moderationService.blockUser(
                  blockerId: myNovaId ?? '',
                  blockedId: contact.id,
                );
                
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Contacto bloqueado exitosamente')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error al bloquear: $e')),
                  );
                }
              }
            },
            child: const Text('Bloquear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
