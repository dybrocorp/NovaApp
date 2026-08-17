import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/domain/models.dart';

class BlockedContactsScreen extends ConsumerStatefulWidget {
  const BlockedContactsScreen({super.key});

  @override
  ConsumerState<BlockedContactsScreen> createState() => _BlockedContactsScreenState();
}

class _BlockedContactsScreenState extends ConsumerState<BlockedContactsScreen> {
  final List<ChatContact> _blockedContacts = [];

  @override
  Widget build(BuildContext context) {
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
            child: _blockedContacts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.block, size: 64, color: Colors.white24),
                        const SizedBox(height: 16),
                        const Text(
                          'No hay contactos bloqueados',
                          style: TextStyle(color: Colors.white54, fontSize: 16),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _blockedContacts.length,
                    itemBuilder: (context, index) {
                      final contact = _blockedContacts[index];
                      return _buildBlockedTile(context, contact);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockedTile(BuildContext context, ChatContact contact) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2C2C2E),
        child: Text(
          contact.name[0].toUpperCase(),
          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(contact.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      subtitle: Text(contact.id, style: const TextStyle(color: Colors.white24, fontSize: 12, fontFamily: 'monospace')),
      trailing: TextButton(
        onPressed: () {
          setState(() {
            _blockedContacts.remove(contact);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${contact.name} desbloqueado')),
          );
        },
        child: const Text('DESBLOQUEAR', style: TextStyle(color: NovaColors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
