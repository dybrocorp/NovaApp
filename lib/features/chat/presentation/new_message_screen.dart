import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/features/chat/presentation/chat_screen.dart';

class NewMessageScreen extends ConsumerStatefulWidget {
  const NewMessageScreen({super.key});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    final supabaseService = ref.read(supabaseServiceProvider);
    // searchUsers already normalizes: strips NOVA- so user can type "AN5G4UHV"
    final results = await supabaseService.searchUsers(trimmed);

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  Future<void> _addContact(Map<String, dynamic> user) async {
    final repo = ref.read(identityRepositoryProvider);
    final myNovaId = await repo.getId();

    if (myNovaId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: no se encontró tu identidad')),
        );
      }
      return;
    }

    final contact = ChatContact(
      id: user['nova_id'] ?? user['id'] ?? '',
      name: user['name'] ?? 'Usuario',
      publicKey: user['public_key'],
      verificationLevel: VerificationLevel.level1,
    );

    // Save locally first (always works)
    await ref.read(chatRepositoryProvider).saveContact(contact);

    // Save to Supabase (non-fatal)
    try {
      final supabaseService = ref.read(supabaseServiceProvider);
      await supabaseService.saveContact({
        'user_nova_id': myNovaId,
        'contact_id': contact.id,
        'contact_name': contact.name,
        'verification_level': 'level1',
      });
    } catch (e) {
      LoggerService.warning('Supabase contact save skipped', error: e, tag: 'Chat');
    }

    ref.invalidate(contactsProvider);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${contact.name} añadido ✓')),
      );
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ChatScreen(contact: contact)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
            position: PopupMenuPosition.under,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'actualizar',
                child: const Text('Actualizar'),
                onTap: () {
                  ref.invalidate(contactsProvider);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Contactos actualizados')),
                  );
                },
              ),
              PopupMenuItem(
                value: 'grupo',
                child: const Text('Nuevo grupo'),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Función de nuevo grupo próximamente')),
                  );
                },
              ),
              PopupMenuItem(
                value: 'invitar',
                child: const Text('Invitar personas'),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Función de invitar próximamente')),
                  );
                },
              ),
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
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar por ID (8 caracteres ej: AN5G4UHV)',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 16),
                  suffixIcon: _isSearching 
                      ? const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                          ),
                        )
                      : const Icon(Icons.search, color: Colors.grey, size: 20),
                  border: InputBorder.none,
                ),
                onChanged: _performSearch,
              ),
            ),
          ),
          // Top Actions
          _buildQuickAction(Icons.group_outlined, 'Nuevo grupo'),
          _buildQuickAction(Icons.alternate_email, 'Buscar por alias'),
          
          // Search Results or Contact List
          Expanded(
            child: _searchResults.isNotEmpty
                ? _buildSearchResults()
                : contactsAsync.when(
                    data: (contacts) {
                      // Alphabetize contacts for demo
                      final sortedContacts = [...contacts]..sort((a, b) => a.name.compareTo(b.name));
                      
                      // Filter out "Notas privadas" from regular contacts (it's in special section)
                      final filteredContacts = sortedContacts.where((contact) => contact.name != 'Notas privadas').toList();
                      
                      // Group by first letter
                      final Map<String, List<ChatContact>> grouped = {};
                      for (var contact in filteredContacts) {
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
                          _buildQuickAction(Icons.refresh, 'Actualizar contactos', subtitle: '¿Falta alguien? Prueba a actualizar.', onTap: () {
                            ref.invalidate(contactsProvider);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Contactos actualizados')),
                            );
                          }),
                          _buildQuickAction(Icons.mail_outline, 'Invitar a NovaApp', onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Función de invitar próximamente')),
                            );
                          }),
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

  Widget _buildQuickAction(IconData icon, String title, {String? subtitle, VoidCallback? onTap}) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2C2C2E),
        child: Icon(icon, color: Colors.white70),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      subtitle: subtitle != null ? Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)) : null,
      onTap: onTap,
    );
  }

  Widget _buildSearchResults() {
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final user = _searchResults[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF2C2C2E),
            child: Text(
              (user['name'] ?? 'U')[0].toUpperCase(),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(
            user['name'] ?? 'Usuario',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            user['nova_id'] ?? '',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.person_add, color: NovaColors.primary),
            onPressed: () => _addContact(user),
          ),
          onTap: () => _addContact(user),
        );
      },
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
