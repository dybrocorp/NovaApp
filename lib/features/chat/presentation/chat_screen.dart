import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:novaapp/shared/widgets/chat_bubble.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/presentation/call_screen.dart';
import 'package:novaapp/features/chat/presentation/attachment_menu.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/core/services/attachment_service.dart';
import 'package:novaapp/shared/widgets/waveform_painter.dart';
import 'package:novaapp/features/chat/presentation/location_picker_screen.dart';
import 'package:latlong2/latlong.dart';
import 'package:novaapp/features/chat/presentation/contact_detail_screen.dart';
import 'package:novaapp/features/chat/presentation/group_info_screen.dart';
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
          msgType = MessageType.contact;
          break;
        case 'location':
          final LatLng? result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const LocationPickerScreen()),
          );
          if (result != null) {
            text = 'Lugar compartido';
            path = '${result.latitude},${result.longitude}'; // Latitude, Longitude for map preview logic
            msgType = MessageType.location;
          }
          break;
        case 'poll':
          // Mock poll data for demonstration
          msgType = MessageType.poll;
          final pollData = PollData(
            question: '¿Cuál es tu color favorito de NovaApp?',
            options: ['Púrpura Profundo', 'Negro Obsidiana', 'Gris Espacial'],
            votes: {0: 12, 1: 8, 2: 5},
          );
          final message = Message(
            senderId: 'me',
            chatId: widget.contact.id,
            type: msgType,
            timestamp: DateTime.now(),
            isMe: true,
            pollData: pollData,
          );
          await ref.read(chatRepositoryProvider).saveMessage(message);
          return;
        case 'location_realtime':
          final duration = data as int;
          text = 'Ubicación en tiempo real ($duration min)';
          msgType = MessageType.location;
          break;
        case 'document':
          path = await service.pickFile();
          text = 'Documento compartido';
          msgType = MessageType.text; // Defaulting to text with file label for now or a custom file type if needed
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      body: Stack(
        children: [
          Column(
            children: [
              _buildHeader(context),
              Expanded(
                child: messagesAsync.when(
                  data: (messages) => ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 12),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
                        return _buildInitialProfileCard(context);
                      }
                      final message = messages[index];
                      return ChatBubble(message: message);
                    },
                  ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, s) => Center(child: Text('Error: $e')),
                ),
              ),
              _buildInputArea(context),
            ],
          ),
          if (_isRecording) _buildRecordingOverlay(context),
        ],
      ),
    );
  }

  Widget _buildInitialProfileCard(BuildContext context) {
    final isPrivateNotes = widget.contact.name == 'Notas privadas';
    final colorScheme = Theme.of(context).colorScheme;
    
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50,
            backgroundColor: isPrivateNotes ? const Color(0xFFE6D7BD) : colorScheme.surface,
            child: isPrivateNotes 
              ? const Icon(Icons.description_outlined, color: Color(0xFF5D4037), size: 50)
              : Text(widget.contact.name[0], style: TextStyle(fontSize: 40, color: colorScheme.onSurface)),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.contact.name,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
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
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colorScheme.onSurface.withValues(alpha: 0.1)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8, bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.white,
        border: Border(bottom: BorderSide(color: colorScheme.onSurface.withValues(alpha: 0.1), width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new, size: 20, color: colorScheme.primary),
            onPressed: () => Navigator.pop(context),
          ),
          CircleAvatar(
            radius: 18,
            backgroundColor: widget.contact.name == 'Notas privadas' ? const Color(0xFFE6D7BD) : colorScheme.surface,
            child: widget.contact.name == 'Notas privadas'
              ? const Icon(Icons.description_outlined, color: Color(0xFF5D4037), size: 18)
              : Text(
                  widget.contact.name[0],
                  style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.bold),
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (widget.contact.name.contains('Grupo')) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => GroupInfoScreen(
                        group: ChatGroup(
                          id: widget.contact.id,
                          name: widget.contact.name,
                          memberIds: ['me', 'user2', 'user3'],
                        ),
                      ),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => ContactDetailScreen(contact: widget.contact)),
                  );
                }
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.contact.name,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _buildVerificationDots(widget.contact.verificationLevel),
                    ],
                  ),
                  Text(
                    'en línea',
                    style: TextStyle(fontSize: 12, color: colorScheme.primary, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.videocam_outlined, color: colorScheme.onSurface.withValues(alpha: 0.7)),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => CallScreen(contactName: widget.contact.name, isVideo: true)),
            ),
          ),
          IconButton(
            icon: Icon(Icons.call_outlined, color: colorScheme.onSurface.withValues(alpha: 0.7)),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => CallScreen(contactName: widget.contact.name)),
            ),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colorScheme.onSurface.withValues(alpha: 0.7)),
            color: colorScheme.surface,
            itemBuilder: (context) => [
              PopupMenuItem(value: 'archivos', child: Text('Todos los archivos', style: TextStyle(color: colorScheme.onSurface))),
              PopupMenuItem(value: 'ajustes', child: Text('Ajustes del chat', style: TextStyle(color: colorScheme.onSurface))),
              PopupMenuItem(value: 'buscar', child: Text('Buscar', style: TextStyle(color: colorScheme.onSurface))),
              PopupMenuItem(value: 'inicio', child: Text('Añadir a la pantalla de inicio', style: TextStyle(color: colorScheme.onSurface))),
              PopupMenuItem(value: 'silenciar', child: Text('Silenciar notificaciones', style: TextStyle(color: colorScheme.onSurface))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingOverlay(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        color: isDark ? Colors.black : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.mic, color: Colors.red),
            const SizedBox(width: 8),
            Text(
              _recordingStartTime != null 
                  ? '${DateTime.now().difference(_recordingStartTime!).inMinutes.toString().padLeft(2, '0')}:${(DateTime.now().difference(_recordingStartTime!).inSeconds % 60).toString().padLeft(2, '0')}'
                  : '00:00',
              style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SizedBox(
                height: 40,
                child: CustomPaint(
                  painter: WaveformPainter(amplitudes: _amplitudes, color: colorScheme.primary),
                ),
              ),
            ),
            if (!_isLocked)
              Row(
                children: [
                  Icon(Icons.chevron_left, color: colorScheme.onSurface.withValues(alpha: 0.3)),
                  Text(' Desliza para cancelar', style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.5), fontSize: 12)),
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

    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.white,
        border: Border(top: BorderSide(color: colorScheme.onSurface.withValues(alpha: 0.05))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Left Attachment Menu Button (+)
            IconButton(
              icon: Icon(Icons.add, color: colorScheme.primary, size: 28),
              onPressed: _showAttachmentMenu,
            ),
            
            // Center Text Field
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _controller,
                  onChanged: (val) => setState(() {}),
                  style: TextStyle(color: colorScheme.onSurface, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Mensaje de NovaApp',
                    hintStyle: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.3)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
            
            const SizedBox(width: 8),
            
            // Right Mic/Send Button
            Stack(
              clipBehavior: Clip.none,
              children: [
                if (_isRecording && !_isLocked)
                  Positioned(
                    top: _dragUpPosition - 60,
                    left: 0,
                    right: 0,
                    child: Icon(Icons.lock_outline, color: colorScheme.onSurface.withValues(alpha: 0.5)),
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
                      color: _isRecording ? Colors.red : colorScheme.primary,
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
}
