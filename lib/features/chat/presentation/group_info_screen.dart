import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';

class GroupInfoScreen extends ConsumerWidget {
  final ChatGroup group;

  const GroupInfoScreen({super.key, required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactsAsync = ref.watch(contactsProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(context),
          SliverToBoxAdapter(
            child: Column(
              children: [
                _buildInfoCard(),
                const SizedBox(height: 24),
                _buildParticipantsSection(context, contactsAsync),
                const SizedBox(height: 32),
                _buildActionTile(Icons.exit_to_app, 'Abandonar grupo', () {}, color: Colors.red),
                _buildActionTile(Icons.delete_outline, 'Eliminar grupo', () {}, color: Colors.red),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliverAppBar(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 250,
      pinned: true,
      backgroundColor: NovaColors.background,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(group.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        background: Stack(
          alignment: Alignment.center,
          children: [
            Container(color: const Color(0xFF2C2C2E)),
            Icon(Icons.group, size: 100, color: Colors.white.withValues(alpha: 0.2)),
            Positioned(
              bottom: 60,
              right: 16,
              child: FloatingActionButton.small(
                onPressed: () {},
                backgroundColor: NovaColors.primary,
                child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          _buildInfoRow('ID de Grupo', group.id, isMono: true),
          const Divider(color: Colors.white10, height: 32),
          _buildInfoRow('Fecha de creación', 'Hoy, 10:45 AM'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isMono = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontFamily: isMono ? 'monospace' : null,
          ),
        ),
      ],
    );
  }

  Widget _buildParticipantsSection(BuildContext context, AsyncValue<List<ChatContact>> contactsAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '${group.memberIds.length} PARTICIPANTES',
            style: const TextStyle(color: NovaColors.primary, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
        ),
        _buildActionTile(Icons.person_add_alt_1, 'Añadir participante', () {}),
        contactsAsync.when(
          data: (contacts) {
            final members = contacts.where((c) => group.memberIds.contains(c.id)).toList();
            return Column(
              children: [
                ...members.map((member) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF2C2C2E),
                    child: Text(member.name[0], style: const TextStyle(color: Colors.white)),
                  ),
                  title: Text(member.name, style: const TextStyle(color: Colors.white)),
                  trailing: _buildVerificationDots(member.verificationLevel),
                  onTap: () {},
                )),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => const SizedBox.shrink(),
        ),
      ],
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
        margin: const EdgeInsets.only(left: 2),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      )),
    );
  }

  Widget _buildActionTile(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white}) {
    return ListTile(
      leading: Icon(icon, color: color.withValues(alpha: 0.8)),
      title: Text(label, style: TextStyle(color: color, fontSize: 16)),
      onTap: onTap,
    );
  }
}
