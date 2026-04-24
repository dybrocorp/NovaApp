import 'package:flutter/material.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

class CallScreen extends StatelessWidget {
  final String contactName;
  final bool isVideo;

  const CallScreen({
    super.key,
    required this.contactName,
    this.isVideo = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (isVideo)
            Positioned.fill(
              child: Container(
                color: Colors.grey[900],
                child: const Center(
                  child: Icon(Icons.videocam_off, size: 80, color: Colors.white24),
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 60),
                const CircleAvatar(
                  radius: 50,
                  backgroundColor: NovaColors.primary,
                  child: Icon(Icons.person, size: 60, color: Colors.white),
                ),
                const SizedBox(height: 24),
                Text(
                  contactName,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                Text(
                  isVideo ? 'Videollamada en curso...' : 'Llamada de voz en curso...',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallActionBtn(icon: Icons.mic_off, label: 'Silencio', color: Colors.white24),
                    _CallActionBtn(icon: Icons.videocam_off, label: 'Cámara', color: Colors.white24),
                    _CallActionBtn(icon: Icons.volume_up, label: 'Altavoz', color: Colors.white24),
                  ],
                ),
                const SizedBox(height: 48),
                FloatingActionButton.large(
                  onPressed: () => Navigator.pop(context),
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.call_end, color: Colors.white),
                ),
                const SizedBox(height: 60),
              ],
            ),
          ),
          if (isVideo)
            Positioned(
              top: 40,
              right: 20,
              child: Container(
                width: 100,
                height: 150,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Center(
                  child: Icon(Icons.person, color: Colors.white24),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CallActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _CallActionBtn({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircleAvatar(
          radius: 30,
          backgroundColor: color,
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
