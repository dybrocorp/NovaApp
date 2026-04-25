import 'package:flutter/material.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

class AttachmentMenu extends StatelessWidget {
  final Function(String type, dynamic data) onSelected;

  const AttachmentMenu({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: const BoxDecoration(
        color: NovaColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 32),
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 4,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            childAspectRatio: 0.85,
            children: [
              _MenuItem(
                icon: Icons.image, 
                color: const Color(0xFF9B51E0), 
                label: 'Galería',
                onTap: () => onSelected('gallery', null),
              ),
              _MenuItem(
                icon: Icons.camera_alt, 
                color: const Color(0xFFEB5757), 
                label: 'Cámara',
                onTap: () => onSelected('camera', null),
              ),
              _MenuItem(
                icon: Icons.person, 
                color: const Color(0xFF2F80ED), 
                label: 'Contacto',
                onTap: () => onSelected('contact', null),
              ),
              _MenuItem(
                icon: Icons.location_on, 
                color: const Color(0xFF27AE60), 
                label: 'Ubicación',
                onTap: () => onSelected('location', null),
              ),
              _MenuItem(
                icon: Icons.description, 
                color: const Color(0xFFF2994A), 
                label: 'Archivo',
                onTap: () => onSelected('document', null),
              ),
              _MenuItem(
                icon: Icons.poll, 
                color: const Color(0xFF56CCF2), 
                label: 'Encuesta',
                onTap: () => onSelected('poll', null),
              ),
              _MenuItem(
                icon: Icons.share_location, 
                color: const Color(0xFFF2C94C), 
                label: 'Tiempo Real',
                onTap: () => onSelected('location_realtime', 15),
              ),
              _MenuItem(
                icon: Icons.more_horiz, 
                color: const Color(0xFF4F4F4F), 
                label: 'Más',
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _MenuItem({required this.icon, required this.color, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
