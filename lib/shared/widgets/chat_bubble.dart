import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/presentation/media_viewer_screen.dart';
import 'package:novaapp/features/settings/presentation/providers/settings_provider.dart';

class ChatBubble extends ConsumerWidget {
  final Message message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final style = settings.bubbleStyle;
    
    final colorScheme = Theme.of(context).colorScheme;
    final isMe = message.isMe;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe && style != BubbleStyle.minimal) 
            CustomPaint(painter: ThreemaTailPainter(isMe: false, color: colorScheme.surface)),
            
          Container(
            margin: EdgeInsets.only(
              left: isMe ? 60 : 0,
              right: isMe ? 0 : 60,
              top: 4,
              bottom: 4,
            ),
            padding: message.type == MessageType.image 
                ? const EdgeInsets.all(4) 
                : const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            decoration: BoxDecoration(
              color: isMe ? colorScheme.primary : colorScheme.surface,
              borderRadius: _getBorderRadius(style, isMe),
            ),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildContent(context),
                  const SizedBox(height: 2),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: _buildStatusRow(context),
                  ),
                ],
              ),
            ),
          ),
          
          if (isMe && style != BubbleStyle.minimal) 
            CustomPaint(painter: ThreemaTailPainter(isMe: true, color: colorScheme.primary)),
          if (isMe) const SizedBox(width: 8),
        ],
      ),
    );
  }

  BorderRadius _getBorderRadius(BubbleStyle style, bool isMe) {
    switch (style) {
      case BubbleStyle.standard:
        return BorderRadius.circular(16);
      case BubbleStyle.geometric:
        return BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 0),
          bottomRight: Radius.circular(isMe ? 0 : 16),
        );
      case BubbleStyle.minimal:
        return BorderRadius.circular(4);
    }
  }

  Widget _buildContent(BuildContext context) {
    switch (message.type) {
      case MessageType.text:
        return _buildTextContent();
      case MessageType.image:
        return _buildImageContent(context);
      case MessageType.voice:
        return _buildVoiceContent();
      case MessageType.location:
        return _buildLocationContent();
      case MessageType.contact:
        return _buildContactContent();
      case MessageType.poll:
        return _buildPollContent();
    }
  }

  Widget _buildPollContent() {
    if (message.pollData == null) return const Text('Error: Poll data missing');
    
    final poll = message.pollData!;
    final int totalVotes = poll.votes.values.fold(0, (sum, count) => sum + count);

    return Container(
      width: 260,
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            poll.question,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 12),
          ...poll.options.asMap().entries.map((entry) {
            final int index = entry.key;
            final String option = entry.value;
            final int votes = poll.votes[index] ?? 0;
            final double percentage = totalVotes > 0 ? (votes / totalVotes) : 0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Stack(
                children: [
                  // Progress Bar Background
                  Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: percentage,
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: NovaColors.primary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  // Option Text and Vote Count
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              option,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '$votes',
                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 4),
          Text(
            '$totalVotes votos • ${poll.isClosed ? "Cerrada" : "En curso"}',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 250,
          height: 150,
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.map, color: Colors.white24, size: 48),
              Positioned(
                bottom: 8,
                left: 8,
                child: Row(
                  children: [
                    Icon(Icons.location_on, color: Colors.red, size: 16),
                    SizedBox(width: 4),
                    Text('Ubicación compartida', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (message.text != null) ...[
          const SizedBox(height: 8),
          Text(message.text!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _buildContactContent() {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFF2C2C2E),
            child: Icon(Icons.person, color: Colors.white70),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.text ?? 'Contacto', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const Text('Haga clic para ver', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextContent() {
    return Text(
      message.text ?? '',
      style: const TextStyle(color: Colors.white, fontSize: 16),
    );
  }

  Widget _buildImageContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () {
            if (message.mediaUrl != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MediaViewerScreen(mediaUrl: message.mediaUrl!),
                ),
              );
            }
          },
          child: Hero(
            tag: message.mediaUrl ?? '',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
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
          ),
        ),
        if (message.text != null) ...[
          const SizedBox(height: 4),
          Text(
            message.text!,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ],
    );
  }

  Widget _buildVoiceContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.play_arrow, color: Colors.white, size: 24),
        const SizedBox(width: 8),
        _buildWaveform(),
        const SizedBox(width: 8),
        const Text('0:05', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }

  Widget _buildWaveform() {
    // Threema-style high-fidelity waveform
    return Row(
      children: List.generate(24, (index) {
        // Create organic-looking waveform heights
        final heights = [4, 8, 12, 16, 14, 18, 22, 16, 12, 8, 10, 14, 18, 24, 20, 16, 12, 8, 6, 4, 8, 12, 6, 4];
        final height = heights[index % heights.length].toDouble();
        
        return Container(
          width: 2.5,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: index < 10 ? 1.0 : 0.3), // Simulated played/unplayed
            borderRadius: BorderRadius.circular(1.2),
          ),
        );
      }),
    );
  }

  Widget _buildStatusRow(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
          style: TextStyle(
            color: isDark ? Colors.white54 : Colors.black45,
            fontSize: 10,
          ),
        ),
        if (message.isMe) ...[
          const SizedBox(width: 4),
          _buildThreemaStatusIcon(message.status),
        ],
      ],
    );
  }

  Widget _buildThreemaStatusIcon(String status) {
    if (status == 'pending') {
      return const Icon(Icons.access_time, color: Colors.white70, size: 12);
    }
    
    // Custom Threema-style status logic
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status == 'read')
          const Icon(Icons.remove_red_eye, color: Colors.white70, size: 13)
        else if (status == 'delivered')
          const Icon(Icons.check, color: Colors.white70, size: 13)
        else if (status == 'sent')
          const Icon(Icons.mail, color: Colors.white70, size: 11),
      ],
    );
  }
}

class ThreemaTailPainter extends CustomPainter {
  final bool isMe;
  final Color color;

  ThreemaTailPainter({required this.isMe, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();

    if (isMe) {
      // Small triangle at bottom right of bubble
      path.moveTo(0, -4);
      path.lineTo(8, -4);
      path.lineTo(0, -12);
      path.close();
    } else {
      // Small triangle at bottom left of bubble
      path.moveTo(16, -4);
      path.lineTo(8, -4);
      path.lineTo(16, -12);
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
