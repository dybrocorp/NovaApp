import 'package:flutter/material.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        title: const Text('Ayuda y Soporte', style: TextStyle(fontSize: 18, color: Colors.white)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSectionTitle('CANALES DE SOPORTE'),
          _buildSupportChannel(
            context,
            Icons.mail_outline,
            'Soporte vía Email',
            'support@novaapp.io',
            () {},
          ),
          _buildSupportChannel(
            context,
            Icons.chat_bubble_outline,
            'Canal de Ayuda (Nova ID)',
            '*SUPPORT',
            () {},
          ),
          const SizedBox(height: 32),
          _buildSectionTitle('DOCUMENTACIÓN LEGAL'),
          _buildLegalTile(
            context,
            'Términos y Condiciones',
            'Última actualización: Abril 2026\n\nBienvenido a NovaApp. Al usar nuestra plataforma, aceptas que el cifrado es tu responsabilidad primaria. No almacenamos tus claves privadas ni tenemos acceso a tus mensajes...\n\n1. Uso del Servicio: NovaApp es una herramienta de mensajería privada...\n2. Privacidad: Tu Nova ID es anónimo por defecto...',
          ),
          _buildLegalTile(
            context,
            'Política de Privacidad',
            'Tu privacidad es el núcleo de NovaApp.\n\n- No recolectamos metadatos personales.\n- Los mensajes se eliminan del servidor tras ser entregados.\n- La sincronización con Supabase está cifrada de extremo a extremo con X25519.',
          ),
          const SizedBox(height: 48),
          Center(
            child: Column(
              children: [
                const Text(
                  'NovaApp v1.0.0 (Build 2026)',
                  style: TextStyle(color: NovaColors.textTertiary, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  'Made with 💜 for Privacy',
                  style: TextStyle(color: NovaColors.primary.withOpacity(0.5), fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: NovaColors.textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSupportChannel(BuildContext context, IconData icon, String title, String value, VoidCallback onTap) {
    return Card(
      color: NovaColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: NovaColors.primary),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(value, style: const TextStyle(color: NovaColors.primary, fontSize: 13)),
        onTap: onTap,
      ),
    );
  }

  Widget _buildLegalTile(BuildContext context, String title, String content) {
    return Card(
      color: NovaColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        iconColor: NovaColors.primary,
        collapsedIconColor: NovaColors.textTertiary,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              content,
              style: const TextStyle(color: NovaColors.textSecondary, fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
