import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/auth/presentation/profile_setup_screen.dart';

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final TextEditingController _idController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _idController.text = 'NOVA-';
  }

  Future<void> _handleRestore() async {
    final text = _idController.text.trim().toUpperCase();
    
    if (text.isEmpty || text == 'NOVA-') {
      setState(() => _error = 'Por favor, ingresa los 8 caracteres de tu ID.');
      return;
    }

    // Ensure it starts with NOVA-
    String id = text;
    if (!id.startsWith('NOVA-')) {
      id = 'NOVA-$text';
    }

    if (!RegExp(r'^NOVA-[A-Z0-9]{8}$').hasMatch(id)) {
      setState(() => _error = 'El ID debe tener el formato NOVA-XXXXXXXX (13 caracteres).');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final repo = ref.read(identityRepositoryProvider);
      await repo.restoreIdentity(id);

      // Attempt to load profile from Supabase
      try {
        final supabaseService = ref.read(supabaseServiceProvider);
        final user = await supabaseService.getUserByNovaId(id);
        if (user != null) {
          if (user['name'] != null) {
            await repo.saveName(user['name']);
          }
          if (user['avatar_url'] != null) {
            // For now, we save the base64 or URL string directly.
            // If it's a URL or base64, we save it as the avatar path.
            await repo.saveAvatarPath(user['avatar_url']);
          }
        }
      } catch (e) {
        LoggerService.error('Could not fetch user profile from Supabase', error: e, tag: 'Auth');
      }
      
      // Refresh provider
      ref.invalidate(identityProvider);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSetupScreen()),
        );
      }
    } catch (e) {
      setState(() => _error = 'Error al restaurar el ID. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: const Text('Restaurar ID'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ingresa tu Nova ID para restaurar tu cuenta.',
              style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _idController,
              style: TextStyle(color: colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'NOVA-XXXXXXXX',
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                errorText: _error,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              ),
              textCapitalization: TextCapitalization.characters,
              maxLength: 13,
              onChanged: (val) {
                if (!val.startsWith('NOVA-')) {
                  _idController.text = 'NOVA-';
                  _idController.selection = TextSelection.fromPosition(
                    const TextPosition(offset: 5),
                  );
                }
              },
            ),
            const SizedBox(height: 16),
            Text(
              'Importante: La restauración solo recupera tu identificación. Los mensajes y contactos deben restaurarse desde un backup de datos.',
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
            const Spacer(),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: NovaColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _isLoading ? null : _handleRestore,
              child: _isLoading 
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('RESTAURAR IDENTIDAD', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
