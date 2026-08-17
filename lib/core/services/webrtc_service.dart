import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'dart:async';

class WebRTCService {
  static final WebRTCService _instance = WebRTCService._internal();
  factory WebRTCService() => _instance;
  WebRTCService._internal();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  io.Socket? _socket;
  
  // High quality configuration with multiple STUN/TURN servers
  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      // Add TURN servers for better connectivity (replace with your own TURN server)
      // {'urls': 'turn:your-turn-server.com:3478', 'username': 'username', 'credential': 'password'},
    ]
  };

  final Map<String, dynamic> _constraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
      {'googImprovedBitrate': true},
      {'googScreencastMinBitrate': 300},
      {'googCpuOveruseDetection': true},
      {'googCpuOveruseEncodeUsage': true},
    ],
  };

  // High quality media constraints for HD video
  final Map<String, dynamic> _mediaConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'highpassFilter': true,
    },
    'video': {
      'mandatory': {
        'minWidth': '1280',
        'minHeight': '720',
        'minFrameRate': '30',
        'maxFrameRate': '60',
      },
      'optional': [
        {'facingMode': 'user'},
        {'width': {'ideal': '1280'}},
        {'height': {'ideal': '720'}},
        {'frameRate': {'ideal': 30, 'max': 60}},
      ],
    },
  };

  // Audio only constraints with high quality audio
  final Map<String, dynamic> _audioOnlyConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'highpassFilter': true,
      'echoCancellationType': 'system',
    },
    'video': false,
  };

  bool _isMuted = false;
  bool _isVideoOff = false;
  bool _isSpeakerOn = false;
  bool _isInitialized = false;

  // Callbacks
  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(String)? onCallEnded;
  Function(String)? onError;

  Future<void> initialize(String signalingServerUrl) async {
    if (_isInitialized) return;
    
    try {
      _socket = io.io(signalingServerUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
      });

      _socket!.connect();
      _setupSocketListeners();
      _isInitialized = true;
    } catch (e) {
      onError?.call('Failed to initialize WebRTC: $e');
    }
  }

  void _setupSocketListeners() {
    _socket?.on('offer', (data) async {
      await _handleOffer(data);
    });

    _socket?.on('answer', (data) async {
      await _handleAnswer(data);
    });

    _socket?.on('ice-candidate', (data) async {
      await _handleIceCandidate(data);
    });

    _socket?.on('user-disconnected', (data) {
      _handleUserDisconnected(data['userId']);
    });
  }

  Future<void> startCall(String targetUserId, {bool isVideoCall = true}) async {
    try {
      final constraints = isVideoCall ? _mediaConstraints : _audioOnlyConstraints;
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      onLocalStream?.call(_localStream!);

      _peerConnection = await createPeerConnection(_iceServers, _constraints);
      
      _peerConnection!.onAddStream = (MediaStream stream) {
        _remoteStream = stream;
        onRemoteStream?.call(stream);
      };

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        _socket?.emit('ice-candidate', {
          'candidate': candidate.toMap(),
          'targetUserId': targetUserId,
        });
      };

      _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          onCallEnded?.call('Connection lost');
        }
      };

      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      final description = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(description);

      _socket?.emit('offer', {
        'sdp': description.toMap(),
        'targetUserId': targetUserId,
        'isVideoCall': isVideoCall,
      });
    } catch (e) {
      onError?.call('Failed to start call: $e');
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    try {
      _peerConnection = await createPeerConnection(_iceServers, _constraints);
      
      _peerConnection!.onAddStream = (MediaStream stream) {
        _remoteStream = stream;
        onRemoteStream?.call(stream);
      };

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        _socket?.emit('ice-candidate', {
          'candidate': candidate.toMap(),
          'targetUserId': data['userId'],
        });
      };

      final constraints = data['isVideoCall'] ? _mediaConstraints : _audioOnlyConstraints;
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      onLocalStream?.call(_localStream!);

      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']),
      );

      final description = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(description);

      _socket?.emit('answer', {
        'sdp': description.toMap(),
        'targetUserId': data['userId'],
      });
    } catch (e) {
      onError?.call('Failed to handle offer: $e');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    try {
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']),
      );
    } catch (e) {
      onError?.call('Failed to handle answer: $e');
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    try {
      final candidate = RTCIceCandidate(
        data['candidate']['candidate'],
        data['candidate']['sdpMid'],
        data['candidate']['sdpMLineIndex'],
      );
      await _peerConnection?.addCandidate(candidate);
    } catch (e) {
      onError?.call('Failed to handle ICE candidate: $e');
    }
  }

  void _handleUserDisconnected(String userId) {
    onCallEnded?.call('User disconnected');
  }

  // Audio/Video controls
  Future<void> toggleMute() async {
    if (_localStream == null) return;
    
    _isMuted = !_isMuted;
    for (var track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
  }

  Future<void> toggleVideo() async {
    if (_localStream == null) return;
    
    _isVideoOff = !_isVideoOff;
    for (var track in _localStream!.getVideoTracks()) {
      track.enabled = !_isVideoOff;
    }
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
  }

  Future<void> switchCamera() async {
    if (_localStream == null) return;
    
    final videoTrack = _localStream!.getVideoTracks().first;
    await Helper.switchCamera(videoTrack);
  }

  // Getters
  bool get isMuted => _isMuted;
  bool get isVideoOff => _isVideoOff;
  bool get isSpeakerOn => _isSpeakerOn;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  Future<void> endCall() async {
    await _localStream?.dispose();
    await _remoteStream?.dispose();
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    
    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _isMuted = false;
    _isVideoOff = false;
    _isSpeakerOn = false;
    
    _socket?.emit('end-call', {});
  }

  void dispose() {
    endCall();
    _socket?.disconnect();
    _socket?.dispose();
    _isInitialized = false;
  }
}
