import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Acerca de NovaApp', style: TextStyle(fontSize: 18))),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.bolt, size: 60, color: Colors.white),
            ),
            const SizedBox(height: 24),
            const Text('NovaApp v2.0 (Premium)', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const Text('Cifrado de grado militar', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 48),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'NovaApp es una plataforma de mensajería enfocada en la privacidad total y la seguridad del usuario. Ningún dato es recolectado ni vendido.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            const Spacer(),
            const Text('© 2026 DybroCorp', style: TextStyle(color: Colors.white24, fontSize: 11)),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
