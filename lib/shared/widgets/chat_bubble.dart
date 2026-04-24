import 'package:flutter/material.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/domain/models.dart';

class ChatBubble extends StatelessWidget {
  final Message message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: message.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(
              left: message.isMe ? 60 : 16,
              right: message.isMe ? 16 : 60,
              top: 4,
              bottom: 4,
            ),
            padding: message.type == MessageType.image 
                ? const EdgeInsets.all(4) 
                : const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            decoration: BoxDecoration(
              color: message.isMe ? NovaColors.primary : NovaColors.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(message.isMe ? 20 : 4),
                bottomRight: Radius.circular(message.isMe ? 4 : 20),
              ),
              boxShadow: [
                if (message.isMe)
                  BoxShadow(
                    color: (message.isMe ? NovaColors.primary : const Color(0xFF2C2C2E)).withValues(alpha: 0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
              ],
            ),
            child: _buildContent(context),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (message.type) {
      case MessageType.text:
        return _buildTextContent();
      case MessageType.image:
        return _buildImageContent();
      case MessageType.voice:
        return _buildVoiceContent();
    }
  }

  Widget _buildTextContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          message.text ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.3),
        ),
        _buildStatusRow(),
      ],
    );
  }

  Widget _buildImageContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.network(
            message.mediaUrl ?? 'https://via.placeholder.com/200',
            width: 250,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              width: 250,
              height: 150,
              color: Colors.white10,
              child: const Icon(Icons.image_not_supported),
            ),
          ),
        ),
        if (message.text != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              message.text!,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 4, top: 4),
          child: _buildStatusRow(),
        ),
      ],
    );
  }

  Widget _buildVoiceContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.play_arrow_rounded,
          color: message.isMe ? Colors.white : NovaColors.primary,
          size: 32,
        ),
        const SizedBox(width: 8),
        _buildWaveform(),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text('0:05', style: TextStyle(color: Colors.white, fontSize: 12)),
            _buildStatusRow(),
          ],
        ),
      ],
    );
  }

  Widget _buildWaveform() {
    return Row(
      children: List.generate(15, (index) {
        final height = (index % 3 + 1) * 6.0;
        return Container(
          width: 3,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }

  Widget _buildStatusRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 10,
          ),
        ),
        if (message.isMe) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.done_all,
            size: 14,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ],
      ],
    );
  }
}
