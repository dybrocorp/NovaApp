import 'package:flutter/material.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/domain/models.dart';

class ContactDetailScreen extends StatelessWidget {
  final ChatContact contact;

  const ContactDetailScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
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
            _buildActionTile(Icons.call_outlined, 'Llamada de voz', () {}),
            _buildActionTile(Icons.videocam_outlined, 'Video llamada', () {}),
            _buildActionTile(Icons.share_outlined, 'Compartir contacto', () {}),
            
            const Divider(color: Colors.white10, height: 48, indent: 16, endIndent: 16),

            _buildActionTile(Icons.block, 'Bloquear contacto', () {}, color: Colors.red),
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
          _buildInfoRow('Clave pública', 'X25519: ${contact.id.substring(0, 8)}...'),
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
}
