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
            crossAxisCount: 3,
            mainAxisSpacing: 24,
            crossAxisSpacing: 24,
            children: [
              _MenuItem(
                icon: Icons.camera_alt, 
                color: Colors.pink[400]!, 
                label: 'Cámara',
                onTap: () => onSelected('camera', null),
              ),
              _MenuItem(
                icon: Icons.mic, 
                color: Colors.blue[400]!, 
                label: 'Grabar',
                onTap: () => onSelected('record', null),
              ),
              _MenuItem(
                icon: Icons.person, 
                color: Colors.indigo[400]!, 
                label: 'Contacto',
                onTap: () => onSelected('contact', null),
              ),
              _MenuItem(
                icon: Icons.image, 
                color: Colors.orange[400]!, 
                label: 'Galería',
                onTap: () => onSelected('gallery', null),
              ),
              _MenuItem(
                icon: Icons.location_on, 
                color: Colors.cyan[400]!, 
                label: 'Ubicación',
                onTap: () => onSelected('location', null),
              ),
              _MenuItem(
                icon: Icons.description, 
                color: Colors.green[400]!, 
                label: 'Documento',
                onTap: () => onSelected('document', null),
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
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.8),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: NovaColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
