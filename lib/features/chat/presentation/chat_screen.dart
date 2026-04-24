import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/shared/widgets/chat_bubble.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/presentation/call_screen.dart';
import 'package:novaapp/features/chat/presentation/attachment_menu.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/core/services/attachment_service.dart';
import 'package:novaapp/shared/widgets/waveform_painter.dart';
import 'package:novaapp/features/chat/presentation/location_picker_screen.dart';
import 'package:latlong2/latlong.dart';
import 'dart:math' as math;

final attachmentServiceProvider = Provider((ref) => AttachmentService());

class ChatScreen extends ConsumerStatefulWidget {
  final ChatContact contact;

  const ChatScreen({super.key, required this.contact});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _isRecording = false;
  bool _isLocked = false;
  double _dragUpPosition = 0;
  double _dragLeftPosition = 0;
  List<double> _amplitudes = [];
  DateTime? _recordingStartTime;

  void _onLongPressStart(LongPressStartDetails details) {
    _startRecording();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_isRecording || _isLocked) return;
    
    setState(() {
      _dragUpPosition = details.localPosition.dy.clamp(-150, 0);
      _dragLeftPosition = details.localPosition.dx.clamp(-150, 0);
    });

    if (_dragUpPosition < -80) {
      setState(() => _isLocked = true);
    }
    
    if (_dragLeftPosition < -100) {
      _cancelRecording();
    }
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_isLocked) return;
    if (_dragLeftPosition < -100) {
      _cancelRecording();
    } else {
      _stopRecordingAndSend();
    }
  }

  Future<void> _startRecording() async {
    final service = ref.read(attachmentServiceProvider);
    try {
      await service.startRecording();
      setState(() {
        _isRecording = true;
        _isLocked = false;
        _dragUpPosition = 0;
        _dragLeftPosition = 0;
        _amplitudes = List.generate(50, (_) => 0.1);
        _recordingStartTime = DateTime.now();
      });
      _updateAmplitudes();
    } catch (e) {
      debugPrint('Error start record: $e');
    }
  }

  void _updateAmplitudes() {
    if (!_isRecording) return;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted || !_isRecording) return;
      setState(() {
        _amplitudes.add(math.Random().nextDouble() * 0.8 + 0.1);
        if (_amplitudes.length > 50) _amplitudes.removeAt(0);
      });
      _updateAmplitudes();
    });
  }

  Future<void> _cancelRecording() async {
    final service = ref.read(attachmentServiceProvider);
    await service.stopRecording();
    setState(() {
      _isRecording = false;
      _isLocked = false;
    });
  }

  Future<void> _stopRecordingAndSend() async {
    final service = ref.read(attachmentServiceProvider);
    final path = await service.stopRecording();
    setState(() {
      _isRecording = false;
      _isLocked = false;
    });
    if (path != null) {
      final message = Message(
        senderId: 'me',
        chatId: widget.contact.id,
        mediaUrl: path,
        type: MessageType.voice,
        timestamp: DateTime.now(),
        isMe: true,
      );
      await ref.read(chatRepositoryProvider).saveMessage(message);
    }
  }

  Future<void> _handleAttachmentSelected(String type, dynamic data) async {
    Navigator.pop(context); // Close menu
    final service = ref.read(attachmentServiceProvider);
    String? path;
    MessageType msgType = MessageType.text;
    String? text;

    try {
      switch (type) {
        case 'camera':
          path = await service.pickImage(ImageSource.camera);
          msgType = MessageType.image;
          break;
        case 'gallery':
          path = await service.pickImage(ImageSource.gallery);
          msgType = MessageType.image;
          break;
        case 'record':
          _startRecording();
          return;
        case 'contact':
          text = await service.pickContact();
          break;
        case 'location':
          final LatLng? result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const LocationPickerScreen()),
          );
          if (result != null) {
            text = '📍 Ubicación: https://www.google.com/maps?q=${result.latitude},${result.longitude}';
          }
          break;
        case 'location_realtime':
          final duration = data as int;
          text = '📡 Ubicación en tiempo real iniciada ($duration min)\nVer mapa: ...';
          break;
        case 'document':
          path = await service.pickFile();
          text = '📄 Archivo adjunto';
          break;
      }

      if (path != null || text != null) {
        final message = Message(
          senderId: 'me',
          chatId: widget.contact.id,
          text: text,
          mediaUrl: path,
          type: msgType,
          timestamp: DateTime.now(),
          isMe: true,
        );
        await ref.read(chatRepositoryProvider).saveMessage(message);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => AttachmentMenu(
        onSelected: _handleAttachmentSelected,
      ),
    );
  }

  Future<void> _sendMessage() async {
    if (_controller.text.isEmpty) return;
    
    final message = Message(
      senderId: 'me',
      chatId: widget.contact.id,
      text: _controller.text,
      timestamp: DateTime.now(),
      isMe: true,
    );

    await ref.read(chatRepositoryProvider).saveMessage(message);
    _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(widget.contact.id));

    return Scaffold(
      backgroundColor: NovaColors.background,
      body: Stack(
        children: [
          Column(
            children: [
              _buildHeader(context),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    image: DecorationImage(
                      image: AssetImage('assets/chat_bg.png'),
                      fit: BoxFit.cover,
                      opacity: 0.15,
                    ),
                  ),
                  child: messagesAsync.when(
                    data: (messages) => ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      itemCount: messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == messages.length) {
                          return _buildInitialProfileCard();
                        }
                        final message = messages[index];
                        return ChatBubble(message: message);
                      },
                    ),
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, s) => Center(child: Text('Error: $e')),
                  ),
                ),
              ),
              _buildInputArea(context),
            ],
          ),
          if (_isRecording) _buildRecordingOverlay(),
        ],
      ),
    );
  }

  Widget _buildInitialProfileCard() {
    final isPrivateNotes = widget.contact.name == 'Notas privadas';
    
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50,
            backgroundColor: isPrivateNotes ? const Color(0xFFE6D7BD) : const Color(0xFF2C2C2E),
            child: isPrivateNotes 
              ? const Icon(Icons.description_outlined, color: Color(0xFF5D4037), size: 50)
              : Text(widget.contact.name[0], style: const TextStyle(fontSize: 40, color: Colors.white)),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.contact.name,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              if (isPrivateNotes) ...[
                const SizedBox(width: 8),
                const Icon(Icons.verified, color: Colors.blue, size: 24),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              children: [
                if (!isPrivateNotes) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.call_outlined, size: 16, color: Colors.grey),
                      const SizedBox(width: 8),
                      Text(widget.contact.id, style: const TextStyle(color: Colors.grey)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.group_outlined, size: 16, color: Colors.grey),
                      SizedBox(width: 8),
                      Text('No tienes grupos en común', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ] else
                  const Text(
                    'En este chat puedes añadir notas visibles solo para ti. Si tienes dispositivos vinculados a tu cuenta, las notas nuevas se sincronizarán.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8, bottom: 12),
      decoration: const BoxDecoration(
        color: NovaColors.background,
        border: Border(bottom: BorderSide(color: Color(0xFF1A1A1A), width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          CircleAvatar(
            radius: 18,
            backgroundColor: widget.contact.name == 'Notas privadas' ? const Color(0xFFE6D7BD) : NovaColors.primary,
            child: widget.contact.name == 'Notas privadas'
              ? const Icon(Icons.description_outlined, color: Color(0xFF5D4037), size: 18)
              : Text(
                  widget.contact.name[0],
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.contact.name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (widget.contact.name == 'Notas privadas') ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified, color: Colors.blue, size: 16),
                    ],
                  ],
                ),
                const Text(
                  'en línea',
                  style: TextStyle(fontSize: 12, color: NovaColors.primaryLight),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined, color: Colors.white),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => CallScreen(contactName: widget.contact.name, isVideo: true)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.call_outlined, color: Colors.white),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => CallScreen(contactName: widget.contact.name)),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            color: const Color(0xFF2C2C2E),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'archivos', child: Text('Todos los archivos')),
              const PopupMenuItem(value: 'ajustes', child: Text('Ajustes del chat')),
              const PopupMenuItem(value: 'buscar', child: Text('Buscar')),
              const PopupMenuItem(value: 'inicio', child: Text('Añadir a la pantalla de inicio')),
              const PopupMenuItem(value: 'silenciar', child: Text('Silenciar notificaciones')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        color: NovaColors.background,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.mic, color: Colors.red),
            const SizedBox(width: 8),
            Text(
              _recordingStartTime != null 
                  ? '${DateTime.now().difference(_recordingStartTime!).inMinutes.toString().padLeft(2, '0')}:${(DateTime.now().difference(_recordingStartTime!).inSeconds % 60).toString().padLeft(2, '0')}'
                  : '00:00',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SizedBox(
                height: 40,
                child: CustomPaint(
                  painter: WaveformPainter(amplitudes: _amplitudes, color: NovaColors.primary),
                ),
              ),
            ),
            if (!_isLocked)
              const Row(
                children: [
                  Icon(Icons.chevron_left, color: Colors.grey),
                  Text(' Desliza para cancelar', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            if (_isLocked)
              TextButton(
                onPressed: _cancelRecording,
                child: const Text('CANCELAR', style: TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea(BuildContext context) {
    if (_isRecording && !_isLocked) {
      return const SizedBox(height: 80); // Placeholder for overlay
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        color: NovaColors.background,
        border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            if (!_isLocked)
              Container(
                decoration: BoxDecoration(
                  color: NovaColors.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFF2C2C2C)),
                ),
                child: IconButton(
                  icon: const Icon(Icons.sentiment_satisfied_alt, color: NovaColors.textTertiary),
                  onPressed: () {},
                ),
              ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: NovaColors.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFF2C2C2C)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onChanged: (val) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'Mensaje de Signal',
                          hintStyle: TextStyle(color: Colors.grey),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.camera_alt_outlined, color: NovaColors.textTertiary),
                      onPressed: () => _handleAttachmentSelected('camera', null),
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file, color: NovaColors.textTertiary),
                      onPressed: _showAttachmentMenu,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Stack(
              clipBehavior: Clip.none,
              children: [
                if (_isRecording && !_isLocked)
                  Positioned(
                    top: _dragUpPosition - 60,
                    left: 0,
                    right: 0,
                    child: const Icon(Icons.lock_outline, color: Colors.white70),
                  ),
                GestureDetector(
                  onLongPressStart: _onLongPressStart,
                  onLongPressMoveUpdate: _onLongPressMoveUpdate,
                  onLongPressEnd: _onLongPressEnd,
                  onTap: () {
                    if (_controller.text.isNotEmpty) {
                      _sendMessage();
                    } else if (_isLocked) {
                      _stopRecordingAndSend();
                    }
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _isRecording ? Colors.red : NovaColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _controller.text.isEmpty 
                          ? (_isRecording ? (_isLocked ? Icons.send : Icons.mic) : Icons.mic) 
                          : Icons.send,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
