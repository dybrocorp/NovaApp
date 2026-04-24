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
                onTap: () => _showLocationOptions(context),
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

  void _showLocationOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: NovaColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.my_location, color: Colors.white),
            title: const Text('Tiempo actual'),
            onTap: () {
              Navigator.pop(context);
              onSelected('location_static', null);
            },
          ),
          ListTile(
            leading: const Icon(Icons.timelapse, color: Colors.white),
            title: const Text('Tiempo real'),
            onTap: () {
              Navigator.pop(context);
              _showDurationPicker(context);
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showDurationPicker(BuildContext context) {
    final durations = [
      {'label': '15 min', 'value': 15},
      {'label': '30 min', 'value': 30},
      {'label': '1 hora', 'value': 60},
      {'label': '8 horas', 'value': 480},
      {'label': '20 horas', 'value': 1200},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: NovaColors.surface,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('Compartir ubicación por...', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...durations.map((d) => ListTile(
            title: Text(d['label'] as String),
            onTap: () {
              Navigator.pop(context);
              onSelected('location_realtime', d['value']);
            },
          )),
          const SizedBox(height: 16),
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
