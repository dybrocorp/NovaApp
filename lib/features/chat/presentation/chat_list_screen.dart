import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/presentation/chat_screen.dart';
import 'package:novaapp/features/chat/presentation/scanner_screen.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/profile/presentation/settings_screen.dart';
import 'package:novaapp/features/chat/presentation/new_message_screen.dart';
import 'package:novaapp/features/chat/presentation/story_viewer_screen.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/features/chat/presentation/contact_detail_screen.dart';
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
          _buildContactsListView(),
          _buildCallsListView(),
          _buildStoriesView(),
        ],
      ),
      bottomNavigationBar: _buildBottomNavigationBar(),
      floatingActionButton: _buildFloatingActionButton(),
    );
  }

  AppBar _buildAppBar(AsyncValue<String?> avatarAsync) {
    String title = 'NovaApp';
    if (_selectedIndex == 1) title = 'Contactos';
    if (_selectedIndex == 2) title = 'Llamadas';
    if (_selectedIndex == 3) title = 'Historias';

    return AppBar(
      backgroundColor: NovaColors.background,
      elevation: 0,
      centerTitle: true,
      title: Text(
        title,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
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
              ? const Icon(Icons.person, color: Colors.white70, size: 20) 
              : null,
          ),
        ),
      ),
      actions: [
        if (_selectedIndex == 0) ...[
          IconButton(icon: const Icon(Icons.camera_alt_outlined), onPressed: () {}),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner), 
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ScannerScreen())),
          ),
        ],
        if (_selectedIndex == 1) 
          IconButton(icon: const Icon(Icons.person_add_alt_1_outlined), onPressed: () {}),
        if (_selectedIndex == 2)
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () {}),
        IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
      ],
    );
  }

  Widget _buildChatListView() {
    final contactsAsync = ref.watch(contactsProvider);

    return Column(
      children: [
        _buildSearchBar('Buscar chat o contacto'),
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
                return matchesSearch;
              }).toList();

              if (filteredContacts.isEmpty && _searchQuery.isEmpty) {
                return _buildEmptyState();
              }

              return ListView.separated(
                itemCount: filteredContacts.length,
                separatorBuilder: (context, index) => const Divider(color: Colors.white10, indent: 80, height: 1),
                itemBuilder: (context, index) {
                  final contact = filteredContacts[index];
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

  Widget _buildContactsListView() {
    final contactsAsync = ref.watch(contactsProvider);

    return Column(
      children: [
        _buildSearchBar('Buscar contacto'),
        Expanded(
          child: contactsAsync.when(
            data: (contacts) {
              // Threema-style: Sort alphabetically and group
              contacts.sort((a, b) => a.name.compareTo(b.name));
              
              return ListView.builder(
                itemCount: contacts.length,
                itemBuilder: (context, index) {
                  final contact = contacts[index];
                  final bool showHeader = index == 0 || contacts[index-1].name[0].toUpperCase() != contact.name[0].toUpperCase();
                  
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showHeader)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          color: Colors.white.withValues(alpha: 0.03),
                          child: Text(
                            contact.name[0].toUpperCase(),
                            style: const TextStyle(color: NovaColors.primary, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ListTile(
                        leading: GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => ContactDetailScreen(contact: contact)),
                          ),
                          child: CircleAvatar(
                            backgroundColor: contact.name == 'Notas privadas' ? const Color(0xFFE6D7BD) : const Color(0xFF2C2C2E),
                            child: contact.name == 'Notas privadas' 
                              ? const Icon(Icons.description_outlined, color: Color(0xFF5D4037))
                              : Text(contact.name[0], style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(contact.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            const SizedBox(width: 8),
                            _buildVerificationDots(contact.verificationLevel),
                          ],
                        ),
                        subtitle: const Text('Disponible', style: TextStyle(color: Colors.grey, fontSize: 13)),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => ChatScreen(contact: contact))),
                      ),
                    ],
                  );
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

  Widget _buildCallsListView() {
    return Column(
      children: [
        _buildSearchBar('Buscar en llamadas'),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.call_missed, size: 64, color: Colors.white24),
                const SizedBox(height: 16),
                const Text('No hay llamadas recientes', style: TextStyle(color: Colors.white70, fontSize: 16)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStoriesView() {
    return Column(
      children: [
        _buildSearchBar('Buscar historias'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _buildStoryTile('Mi historia', 'Añadir a mi historia', isMe: true),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text('HISTORIAS RECIENTES', style: TextStyle(color: NovaColors.primary, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              _buildStoryTile('Alex Rivera', 'Hace 2 horas', hasUpdate: true),
              _buildStoryTile('Maria Lopez', 'Hace 5 horas', hasUpdate: true),
              _buildStoryTile('Juan Perez', 'Ayer', hasUpdate: false),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStoryTile(String name, String time, {bool isMe = false, bool hasUpdate = false}) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: hasUpdate ? Border.all(color: NovaColors.primary, width: 2) : null,
        ),
        child: CircleAvatar(
          radius: 24,
          backgroundColor: const Color(0xFF2C2C2E),
          child: isMe 
            ? const Icon(Icons.add, color: Colors.white)
            : Text(name[0], style: const TextStyle(color: Colors.white)),
        ),
      ),
      title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      subtitle: Text(time, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => StoryViewerScreen(
              contactName: name,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchBar(String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: TextField(
          onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
            icon: const Icon(Icons.search, color: Colors.grey, size: 20),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return BottomNavigationBar(
      backgroundColor: const Color(0xFF0F0F0F),
      selectedItemColor: NovaColors.primary,
      unselectedItemColor: Colors.grey,
      currentIndex: _selectedIndex,
      onTap: (index) => setState(() => _selectedIndex = index),
      type: BottomNavigationBarType.fixed,
      showSelectedLabels: true,
      showUnselectedLabels: true,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline), activeIcon: Icon(Icons.chat_bubble), label: 'Chats'),
        BottomNavigationBarItem(icon: Icon(Icons.person_outline), activeIcon: Icon(Icons.person), label: 'Contactos'),
        BottomNavigationBarItem(icon: Icon(Icons.call_outlined), activeIcon: Icon(Icons.call), label: 'Llamadas'),
        BottomNavigationBarItem(icon: Icon(Icons.filter_none_outlined), activeIcon: Icon(Icons.filter_none), label: 'Historias'),
      ],
    );
  }

  Widget _buildFloatingActionButton() {
    if (_selectedIndex == 2) return const SizedBox.shrink();

    return FloatingActionButton(
      heroTag: 'main_fab',
      backgroundColor: NovaColors.primary,
      onPressed: () {
        if (_selectedIndex == 1) {
          // Add contact behavior
        } else {
          Navigator.push(context, MaterialPageRoute(builder: (context) => const NewMessageScreen()));
        }
      },
      child: Icon(_selectedIndex == 1 ? Icons.person_add : Icons.message, color: Colors.white),
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

  Widget _buildChatListItem(ChatContact contact) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 28,
        backgroundColor: const Color(0xFF2C2C2E),
        child: Text(
          contact.name[0], 
          style: const TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    contact.name, 
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                _buildVerificationDots(contact.verificationLevel),
              ],
            ),
          ),
          Text(
            contact.lastMessageTime != null 
              ? '${contact.lastMessageTime!.hour}:${contact.lastMessageTime!.minute.toString().padLeft(2, '0')}'
              : '11:28', 
            style: const TextStyle(color: Colors.grey, fontSize: 12)
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4.0),
        child: Row(
          children: [
            _buildMessageStatusIcon('read'), // Placeholder for status
            const SizedBox(width: 6),
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

  Widget _buildMessageStatusIcon(String status) {
    switch (status) {
      case 'read':
        return const Icon(Icons.remove_red_eye, color: NovaColors.primary, size: 14);
      case 'delivered':
        return const Icon(Icons.done_all, color: Colors.grey, size: 16);
      case 'sent':
        return const Icon(Icons.done, color: Colors.grey, size: 16);
      default:
        return const SizedBox.shrink();
    }
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
