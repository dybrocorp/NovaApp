import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
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
              subtitle: const Text('Todo el que tenga tu número podrá verte.', style: TextStyle(color: NovaColors.textTertiary)),
              trailing: _privacyOption == 'Cualquiera' ? const Icon(Icons.check, color: NovaColors.primary) : null,
              onTap: () {
                setState(() => _privacyOption = 'Cualquiera');
                Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('Nadie', style: TextStyle(color: Colors.white)),
              subtitle: const Text('No aparecerás en los resultados de búsqueda por número.', style: TextStyle(color: NovaColors.textTertiary)),
              trailing: _privacyOption == 'Nadie' ? const Icon(Icons.check, color: NovaColors.primary) : null,
              onTap: () {
                setState(() => _privacyOption = 'Nadie');
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
                    backgroundImage: _profileImage != null ? FileImage(_profileImage!) : null,
                    child: _profileImage == null 
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
                            '¿Quién puede encontrarme con mi número?',
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
                await repo.saveName('${_firstNameController.text} ${_lastNameController.text}'.trim());
                if (_profileImage != null) {
                  await repo.saveAvatarPath(_profileImage!.path);
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
