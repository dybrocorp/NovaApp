import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/presentation/chat_screen.dart';
import 'package:novaapp/features/chat/presentation/scanner_screen.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/profile/presentation/settings_screen.dart';
import 'package:novaapp/features/chat/presentation/new_message_screen.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  int _selectedIndex = 0;
  String _searchQuery = '';
  String _activeFilter = 'Todos';

  @override
  Widget build(BuildContext context) {
    final avatarAsync = ref.watch(avatarProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: _buildAppBar(avatarAsync),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildChatListView(),
          _buildPlaceholderView('Llamadas', Icons.call),
          _buildPlaceholderView('Historias', Icons.filter_none),
        ],
      ),
      bottomNavigationBar: _buildBottomNavigationBar(),
      floatingActionButton: _buildFloatingActionButton(),
    );
  }

  AppBar _buildAppBar(AsyncValue<String?> avatarAsync) {
    return AppBar(
      backgroundColor: NovaColors.background,
      elevation: 0,
      title: const Text(
        'NovaApp',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
      ),
      leading: Padding(
        padding: const EdgeInsets.all(8.0),
        child: GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen())),
          child: CircleAvatar(
            backgroundColor: const Color(0xFF2C2C2E),
            backgroundImage: avatarAsync.value != null 
              ? FileImage(File(avatarAsync.value!)) 
              : null,
            child: avatarAsync.value == null 
              ? const Icon(Icons.person, color: Colors.white70) 
              : null,
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.camera_alt_outlined, color: Colors.white),
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ScannerScreen())),
        ),
        IconButton(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          onPressed: () {},
        ),
      ],
    );
  }

  Widget _buildChatListView() {
    final contactsAsync = ref.watch(contactsProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(30),
            ),
            child: TextField(
              onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Buscar chat o contacto',
                hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                icon: Icon(Icons.search, color: Colors.grey, size: 20),
                border: InputBorder.none,
              ),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _buildFilterChip('Todos'),
              const SizedBox(width: 8),
              _buildFilterChip('Favoritos'),
              const SizedBox(width: 8),
              _buildFilterChip('Grupos'),
            ],
          ),
        ),
        Expanded(
          child: contactsAsync.when(
            data: (contacts) {
              final filteredContacts = contacts.where((contact) {
                final matchesSearch = contact.name.toLowerCase().contains(_searchQuery);
                final matchesFilter = _activeFilter == 'Todos' || 
                                     (_activeFilter == 'Favoritos' && (contact.lastMessage?.contains('Melo') ?? false)) ||
                                     (_activeFilter == 'Grupos' && (contact.name.contains('Soporte') || contact.name.contains('NovaApp')));
                return matchesSearch && matchesFilter;
              }).toList();

              if (filteredContacts.isEmpty && _searchQuery.isEmpty) {
                return _buildEmptyState();
              }

              return ListView.builder(
                itemCount: filteredContacts.length + 1,
                itemBuilder: (context, index) {
                  final hasArchived = filteredContacts.any((c) => c.isArchived);
                  if (index == 0 && _searchQuery.isEmpty) {
                    return hasArchived ? _buildArchivedTile() : const SizedBox.shrink();
                  }
                  final contact = filteredContacts[_searchQuery.isEmpty ? index - 1 : index];
                  return _buildChatListItem(contact);
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, s) => Center(child: Text('Error: $e')),
          ),
        ),
      ],
    );
  }

  Widget _buildArchivedTile() {
    return const ListTile(
      leading: CircleAvatar(
        backgroundColor: Color(0xFF2C2C2E),
        child: Icon(Icons.archive_outlined, color: Colors.white70),
      ),
      title: Text('Archivados', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      trailing: Text('0', style: TextStyle(color: NovaColors.primary, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildChatListItem(ChatContact contact) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 28,
        backgroundColor: NovaColors.primary,
        child: Text(contact.name[0], style: const TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(contact.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
          const Text('11:28', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
      subtitle: Row(
        children: [
          const Icon(Icons.done_all, color: Colors.blue, size: 16),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              contact.lastMessage ?? 'No hay mensajes',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => ChatScreen(contact: contact))),
    );
  }

  Widget _buildPlaceholderView(String title, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Próximamente en NovaApp', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return BottomNavigationBar(
      backgroundColor: const Color(0xFF0F0F0F),
      selectedItemColor: Colors.white,
      unselectedItemColor: Colors.grey,
      currentIndex: _selectedIndex,
      onTap: (index) => setState(() => _selectedIndex = index),
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.chat_bubble), label: 'Chats'),
        BottomNavigationBarItem(icon: Icon(Icons.call_outlined), activeIcon: Icon(Icons.call), label: 'Llamadas'),
        BottomNavigationBarItem(icon: Icon(Icons.filter_none_outlined), activeIcon: Icon(Icons.filter_none), label: 'Historias'),
      ],
    );
  }

  Widget _buildFloatingActionButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'camera_fab',
          backgroundColor: const Color(0xFF1C1C1E),
          onPressed: () {},
          child: const Icon(Icons.camera_alt, color: Colors.white),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'new_chat_fab',
          backgroundColor: NovaColors.primary,
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const NewMessageScreen())),
          child: const Icon(Icons.edit, color: Colors.white),
        ),
      ],
    );
  }

  Widget _buildFilterChip(String label) {
    final isSelected = _activeFilter == label;
    return GestureDetector(
      onTap: () => setState(() => _activeFilter = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10362D) : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(20),
          border: isSelected ? Border.all(color: const Color(0xFF1E5C4E)) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF25D366) : Colors.grey,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Todavía no tienes chats.\nEnvía un mensaje a quien quieras para empezar.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: NovaColors.primary),
            onPressed: () async {
              await ref.read(chatRepositoryProvider).saveContact(ChatContact(id: 'NOVA1', name: 'Axel', lastMessage: 'Melo'));
              await ref.read(chatRepositoryProvider).saveContact(ChatContact(id: '+123456789', name: 'Soporte NovaApp', lastMessage: 'Bienvenido'));
              await ref.read(chatRepositoryProvider).saveContact(ChatContact(id: 'me_notes', name: 'Notas privadas', lastMessage: 'Notas personales'));
              ref.invalidate(contactsProvider);
            },
            child: const Text('AGREGAR CHATS DE PRUEBA'),
          ),
        ],
      ),
    );
  }
}
