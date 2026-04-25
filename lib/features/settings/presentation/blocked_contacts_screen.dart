import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';

class BlockedContactsScreen extends ConsumerWidget {
  const BlockedContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // For this parity demo, we'll use a mocked list or filter existing contacts
    final contactsAsync = ref.watch(contactsProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Contactos bloqueados', style: TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'No recibirás mensajes ni llamadas de los contactos que hayas bloqueado.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: contactsAsync.when(
              data: (contacts) {
                // Mock a few blocked contacts for UI parity
                return ListView(
                  children: [
                    _buildBlockedTile(context, 'Spam User', 'NO-SPAM-123'),
                    _buildBlockedTile(context, 'Bot Account', 'NO-BOT-999'),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, s) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockedTile(BuildContext context, String name, String id) {
    return ListTile(
      leading: const CircleAvatar(
        backgroundColor: Color(0xFF2C2C2E),
        child: Icon(Icons.person, color: Colors.white70),
      ),
      title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      subtitle: Text(id, style: const TextStyle(color: Colors.white24, fontSize: 12, fontFamily: 'monospace')),
      trailing: TextButton(
        onPressed: () {},
        child: const Text('DESBLOQUEAR', style: TextStyle(color: NovaColors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
