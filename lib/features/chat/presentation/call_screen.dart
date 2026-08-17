import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:novaapp/core/services/webrtc_service.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

class CallScreen extends StatefulWidget {
  final String contactId;
  final String contactName;
  final bool isVideo;

  const CallScreen({
    super.key,
    required this.contactId,
    required this.contactName,
    this.isVideo = true,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final WebRTCService _webrtcService = WebRTCService();
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  bool _isConnected = false;
  bool _isMuted = false;
  bool _isVideoOff = false;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _initializeRenderers();
    if (!mounted) return;
    await _initializeCall();
  }

  Future<void> _initializeRenderers() async {
    _localRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    _remoteRenderer = RTCVideoRenderer();
    await _remoteRenderer!.initialize();
    setState(() {});
  }

  Future<void> _initializeCall() async {
    _webrtcService.onLocalStream = (stream) {
      _localRenderer?.srcObject = stream;
      setState(() {});
    };

    _webrtcService.onRemoteStream = (stream) {
      _remoteRenderer?.srcObject = stream;
      setState(() {
        _isConnected = true;
      });
    };

    _webrtcService.onCallEnded = (reason) {
      if (mounted) Navigator.pop(context);
    };

    _webrtcService.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $error')),
        );
      }
    };

    final signalingServerUrl = dotenv.env['SIGNALING_SERVER_URL'] ?? '';
    if (signalingServerUrl.isEmpty) {
      _webrtcService.onError?.call(
        'Falta configurar SIGNALING_SERVER_URL en .env',
      );
      return;
    }

    await _webrtcService.initialize(signalingServerUrl);

    await _webrtcService.startCall(widget.contactId, isVideoCall: widget.isVideo);
  }

  @override
  void dispose() {
    _localRenderer?.dispose();
    _remoteRenderer?.dispose();
    _webrtcService.dispose();
    super.dispose();
  }

  void _toggleMute() {
    _webrtcService.toggleMute();
    setState(() {
      _isMuted = _webrtcService.isMuted;
    });
  }

  void _toggleVideo() {
    _webrtcService.toggleVideo();
    setState(() {
      _isVideoOff = _webrtcService.isVideoOff;
    });
  }

  void _endCall() {
    _webrtcService.endCall();
    Navigator.pop(context);
  }

  void _switchCamera() {
    _webrtcService.switchCamera();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Remote video (full screen)
            if (widget.isVideo && _remoteRenderer != null)
              Positioned.fill(
                child: RTCVideoView(_remoteRenderer!),
              )
            else
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 60,
                        backgroundColor: NovaColors.primary,
                        child: Text(
                          widget.contactName.isNotEmpty
                              ? widget.contactName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            fontSize: 48,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        widget.contactName,
                        style: const TextStyle(
                          fontSize: 24,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isConnected ? 'Conectado' : 'Conectando...',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Local video (picture-in-picture)
            if (widget.isVideo && _localRenderer != null)
              Positioned(
                top: 16,
                right: 16,
                child: Container(
                  width: 120,
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: RTCVideoView(_localRenderer!),
                  ),
                ),
              ),

            // Controls
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  // Mute/Video controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildControlButton(
                        icon: _isMuted ? Icons.mic_off : Icons.mic,
                        backgroundColor: _isMuted ? Colors.red : Colors.white.withValues(alpha: 0.2),
                        onPressed: _toggleMute,
                      ),
                      const SizedBox(width: 16),
                      if (widget.isVideo)
                        _buildControlButton(
                          icon: _isVideoOff ? Icons.videocam_off : Icons.videocam,
                          backgroundColor: _isVideoOff ? Colors.red : Colors.white.withValues(alpha: 0.2),
                          onPressed: _toggleVideo,
                        ),
                      const SizedBox(width: 16),
                      if (widget.isVideo)
                        _buildControlButton(
                          icon: Icons.flip_camera_ios,
                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                          onPressed: _switchCamera,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // End call button
                  _buildEndCallButton(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildEndCallButton() {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.call_end, color: Colors.white, size: 32),
        onPressed: _endCall,
      ),
    );
  }
}
