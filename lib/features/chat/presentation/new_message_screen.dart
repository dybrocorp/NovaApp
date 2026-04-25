import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/features/chat/presentation/chat_screen.dart';

class NewMessageScreen extends ConsumerWidget {
  const NewMessageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactsAsync = ref.watch(contactsProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Nuevo mensaje'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'actualizar', child: Text('Actualizar')),
              const PopupMenuItem(value: 'grupo', child: Text('Nuevo grupo')),
              const PopupMenuItem(value: 'invitar', child: Text('Invitar personas')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const TextField(
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Nombre, alias o número',
                  hintStyle: TextStyle(color: Colors.grey, fontSize: 16),
                  suffixIcon: Icon(Icons.apps, color: Colors.grey, size: 20),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          // Top Actions
          _buildQuickAction(Icons.group_outlined, 'Nuevo grupo'),
          _buildQuickAction(Icons.alternate_email, 'Buscar por alias'),
          _buildQuickAction(Icons.tag, 'Buscar por número de teléfono'),
          
          // Contact List
          Expanded(
            child: contactsAsync.when(
              data: (contacts) {
                // Alphabetize contacts for demo
                final sortedContacts = [...contacts]..sort((a, b) => a.name.compareTo(b.name));
                
                // Group by first letter
                final Map<String, List<ChatContact>> grouped = {};
                for (var contact in sortedContacts) {
                  final char = contact.name[0].toUpperCase();
                  grouped.putIfAbsent(char, () => []).add(contact);
                }

                final sections = grouped.keys.toList()..sort();

                return ListView(
                  children: [
                    for (var char in sections) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
                        child: Text(
                          char,
                          style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
                        ),
                      ),
                      for (var contact in grouped[char]!) 
                        _buildContactTile(context, contact),
                    ],
                    // Special Section
                    _buildSpecialSection(context),
                    const Divider(color: Colors.white10),
                    // Bottom Actions
                    _buildQuickAction(Icons.refresh, 'Actualizar contactos', subtitle: '¿Falta alguien? Prueba a actualizar.'),
                    _buildQuickAction(Icons.mail_outline, 'Invitar a NovaApp'),
                    const SizedBox(height: 20),
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

  Widget _buildQuickAction(IconData icon, String title, {String? subtitle}) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2C2C2E),
        child: Icon(icon, color: Colors.white70),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      subtitle: subtitle != null ? Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)) : null,
      onTap: () {},
    );
  }

  Widget _buildContactTile(BuildContext context, ChatContact contact) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2C2C2E),
        child: Text(contact.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              contact.name, 
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _buildVerificationDots(contact.verificationLevel),
        ],
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => ChatScreen(contact: contact))),
    );
  }

  Widget _buildVerificationDots(VerificationLevel level) {
    int count = 1;
    Color color = Colors.red;
    
    if (level == VerificationLevel.level2) {
      count = 2;
      color = Colors.orange;
    } else if (level == VerificationLevel.level3) {
      count = 3;
      color = Colors.green;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (index) => Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.only(right: 2),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      )),
    );
  }

  Widget _buildSpecialSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 16, top: 16, bottom: 8),
          child: Text('N', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFE6D7BD),
            child: Icon(Icons.description_outlined, color: Color(0xFF5D4037)),
          ),
          title: const Row(
            children: [
              Text('Notas privadas', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
              SizedBox(width: 4),
              Icon(Icons.verified, size: 16, color: Colors.blue),
            ],
          ),
          onTap: () {},
        ),
      ],
    );
  }
}
