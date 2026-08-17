import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/core/services/supabase_service.dart' as supabase;
import 'package:novaapp/core/services/encryption_service.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/chat/presentation/chat_list_screen.dart';

class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  String _namePreview = 'nova user';
  File? _profileImage;
  String _privacyOption = 'Cualquiera';

  @override
  void initState() {
    super.initState();
    _firstNameController.addListener(_updateNamePreview);
    _lastNameController.addListener(_updateNamePreview);
    _loadExistingProfile();
  }

  String? _base64Avatar;

  Future<void> _loadExistingProfile() async {
    final repo = ref.read(identityRepositoryProvider);
    final existingName = await repo.getName();
    if (existingName != null && existingName.isNotEmpty) {
      setState(() {
        _firstNameController.text = existingName;
        _namePreview = existingName;
      });
    }

    final existingAvatar = await repo.getAvatarPath();
    if (existingAvatar != null && existingAvatar.isNotEmpty) {
      setState(() {
        // We know from recovery_screen that we save the base64 string in avatarPath
        if (existingAvatar.length > 200) { // arbitrary length check to assume base64
          _base64Avatar = existingAvatar;
        } else {
          // It's a local file path
          _profileImage = File(existingAvatar);
        }
      });
    }
  }

  void _updateNamePreview() {
    setState(() {
      final first = _firstNameController.text.trim();
      final last = _lastNameController.text.trim();
      
      if (first.isEmpty && last.isEmpty) {
        _namePreview = 'nova user';
      } else {
        _namePreview = '$first $last'.trim();
      }
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      setState(() {
        _profileImage = File(pickedFile.path);
      });
    }
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: NovaColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white),
              title: const Text('Tomar foto', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.white),
              title: const Text('Elegir de galería', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showPrivacyOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: NovaColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                '¿Quién puede encontrarme?',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              title: const Text('Cualquiera', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Todo el que tenga tu ID de Nova podrá agregarte.', style: TextStyle(color: NovaColors.textTertiary)),
              trailing: _privacyOption == 'Cualquiera' ? const Icon(Icons.check, color: NovaColors.primary) : null,
              onTap: () {
                setState(() => _privacyOption = 'Cualquiera');
                Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('Solo por QR', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Solo podrán agregarte escaneando tu código QR.', style: TextStyle(color: NovaColors.textTertiary)),
              trailing: _privacyOption == 'Solo por QR' ? const Icon(Icons.check, color: NovaColors.primary) : null,
              onTap: () {
                setState(() => _privacyOption = 'Solo por QR');
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Completa tu perfil'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const Text(
              'Tu perfil es visible para las personas a las que les envías mensajes, tus contactos y tus grupos. Más información',
              textAlign: TextAlign.center,
              style: TextStyle(color: NovaColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 32),
            // Avatar Picker
            GestureDetector(
              onTap: _showImagePickerOptions,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 54,
                    backgroundColor: const Color(0xFFF1EEDE),
                    backgroundImage: _profileImage != null 
                        ? FileImage(_profileImage!) 
                        : (_base64Avatar != null ? MemoryImage(base64Decode(_base64Avatar!)) : null) as ImageProvider?,
                    child: (_profileImage == null && _base64Avatar == null)
                        ? const Icon(Icons.person, size: 64, color: Colors.grey)
                        : null,
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Color(0xFF2C2C2C),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.camera_alt, size: 20, color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _namePreview, 
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)
            ),
            const SizedBox(height: 48),
            // Inputs
            _buildTextField(
              controller: _firstNameController,
              label: 'Nombre (obligatorio)',
              hint: 'Ej. Juan',
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _lastNameController,
              label: 'Apellido (opcional)',
              hint: 'Ej. Pérez',
            ),
            const SizedBox(height: 40),
            InkWell(
              onTap: _showPrivacyOptions,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12.0),
                child: Row(
                  children: [
                    const Icon(Icons.group_outlined, color: NovaColors.textSecondary),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '¿Quién puede encontrarme con mi ID?',
                            style: TextStyle(color: Colors.white, fontSize: 15),
                          ),
                          Text(
                            _privacyOption,
                            style: const TextStyle(color: NovaColors.textTertiary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B414E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: () async {
              if (_firstNameController.text.isNotEmpty) {
                final repo = ref.read(identityRepositoryProvider);
                final fullName = '${_firstNameController.text} ${_lastNameController.text}'.trim();
                await repo.saveName(fullName);
                if (_profileImage != null) {
                  await repo.saveAvatarPath(_profileImage!.path);
                }

                // Sync with Supabase (optional - never blocks navigation)
                try {
                  final supabaseService = ref.read(supabase.supabaseServiceProvider);
                  final novaId = await repo.getId();
                  LoggerService.debug('Nova ID from repo: $novaId', tag: 'Auth');
                  
                  if (supabaseService.client == null) {
                    LoggerService.warning('Supabase client is not initialized', tag: 'Auth');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Supabase no está configurado. Verifica el archivo .env')),
                      );
                    }
                  } else {
                    LoggerService.debug('Supabase client is initialized', tag: 'Auth');
                  }
                  
                  final currentUser = supabaseService.currentUser;
                  LoggerService.debug('Current user: ${currentUser?.id}', tag: 'Auth');
                  
                  if (novaId != null && currentUser != null) {
                    final encryptionService = ref.read(encryptionServiceProvider);
                    await encryptionService.ensureKeyPair();
                    final publicKey = await encryptionService.getPublicKey();
                    LoggerService.debug('Public key set', tag: 'Auth');
                    
                    if (publicKey != null) {
                      await supabaseService.updatePublicKey(publicKey);
                    }
                    
                    String? base64Avatar;
                    if (_profileImage != null) {
                      try {
                        final bytes = await _profileImage!.readAsBytes();
                        base64Avatar = base64Encode(bytes);
                      } catch (e) {
                        LoggerService.error('Error encoding avatar', error: e, tag: 'Auth');
                      }
                    }

                    final synced = await supabaseService.createOrUpdateProfile(
                      novaId, 
                      fullName,
                      avatarBase64: base64Avatar,
                    );
                    LoggerService.debug('Profile sync result: $synced', tag: 'Auth');
                    
                    if (context.mounted && synced) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Perfil sincronizado con Supabase ✓')),
                      );
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Error al sincronizar perfil con Supabase')),
                      );
                    }
                  } else {
                    LoggerService.warning('Cannot sync: missing novaId or currentUser', tag: 'Auth');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Error: Usuario no autenticado en Supabase')),
                      );
                    }
                  }
                } catch (e) {
                  LoggerService.error('Supabase sync error', error: e, tag: 'Auth');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error de sincronización: $e')),
                    );
                  }
                }
                
                if (context.mounted) {
                  ref.invalidate(nameProvider);
                  ref.invalidate(avatarProvider);
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const ChatListScreen()),
                    (route) => false,
                  );
                }
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Por favor, ingresa tu nombre.')),
                );
              }
            },
            child: const Text('SIGUIENTE'),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: NovaColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: NovaColors.textTertiary, fontSize: 12)),
          TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFF444444)),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}
