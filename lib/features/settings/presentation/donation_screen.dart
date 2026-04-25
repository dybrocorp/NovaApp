import 'package:flutter/material.dart';

class DonationScreen extends StatelessWidget {
  const DonationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Apoyar a NovaApp', style: TextStyle(fontSize: 18))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.favorite, size: 80, color: Colors.redAccent),
          const SizedBox(height: 24),
          const Text(
            'NovaApp es libre de publicidad y rastreadores.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Tu apoyo nos ayuda a pagar los servidores y seguir desarrollando funciones de seguridad de primer nivel.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 40),
          _buildDonationOption(context, 'Pequeño café', '2.99€'),
          _buildDonationOption(context, 'Cena de desarrollador', '14.99€'),
          _buildDonationOption(context, 'Partidario Platino', '49.99€'),
          const SizedBox(height: 40),
          const Text(
            'Gracias por ser parte de la revolución de la privacidad.',
            textAlign: TextAlign.center,
            style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildDonationOption(BuildContext context, String title, String price) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        tileColor: colorScheme.surface,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(price, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        onTap: () {},
      ),
    );
  }
}
