import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Video call quality levels.
enum VideoQuality { low480p, medium720p, high1080p }

/// Video call state management.
enum VideoCallState { idle, calling, ringing, connected, reconnecting, ended }

class VideoCallService {
  VideoCallState _state = VideoCallState.idle;
  VideoCallState get state => _state;

  VideoQuality _currentQuality = VideoQuality.medium720p;
  VideoQuality get currentQuality => _currentQuality;

  bool _isFrontCamera = true;
  bool get isFrontCamera => _isFrontCamera;

  bool _isPiPMode = false;
  bool get isPiPMode => _isPiPMode;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isVideoEnabled = true;
  bool get isVideoEnabled => _isVideoEnabled;

  int _bitrate = 500; // kbps
  int get bitrate => _bitrate;

  double _frameRate = 30;
  double get frameRate => _frameRate;

  final StreamController<VideoCallState> _stateController =
      StreamController<VideoCallState>.broadcast();
  Stream<VideoCallState> get onStateChanged => _stateController.stream;

  // ===== QUALITY ADAPTATION =====

  /// Automatically adapts resolution based on network/CPU/battery conditions.
  void adaptQuality({
    required double packetLoss,
    required int latencyMs,
    required double cpuUsage, // 0.0 - 1.0
    required int batteryLevel, // 0 - 100
    required bool isCharging,
  }) {
    VideoQuality newQuality = _currentQuality;

    // Degrade quality on poor conditions
    if (packetLoss > 0.05 || latencyMs > 200 || cpuUsage > 0.8 || (!isCharging && batteryLevel < 20)) {
      if (_currentQuality == VideoQuality.high1080p) {
        newQuality = VideoQuality.medium720p;
      } else if (_currentQuality == VideoQuality.medium720p) {
        newQuality = VideoQuality.low480p;
      }
    }
    // Upgrade quality on good conditions
    else if (packetLoss < 0.01 && latencyMs < 100 && cpuUsage < 0.5 && (isCharging || batteryLevel > 50)) {
      if (_currentQuality == VideoQuality.low480p) {
        newQuality = VideoQuality.medium720p;
      } else if (_currentQuality == VideoQuality.medium720p) {
        newQuality = VideoQuality.high1080p;
      }
    }

    if (newQuality != _currentQuality) {
      _currentQuality = newQuality;
      _applyQuality(newQuality);
      LoggerService.info('Video quality adapted: $newQuality', tag: 'VideoCall');
    }
  }

  void _applyQuality(VideoQuality quality) {
    switch (quality) {
      case VideoQuality.low480p:
        _bitrate = 300;
        _frameRate = 24;
        break;
      case VideoQuality.medium720p:
        _bitrate = 500;
        _frameRate = 30;
        break;
      case VideoQuality.high1080p:
        _bitrate = 1000;
        _frameRate = 30;
        break;
    }
  }

  /// Returns resolution dimensions for the current quality.
  (int width, int height) getResolution() {
    switch (_currentQuality) {
      case VideoQuality.low480p:
        return (640, 480);
      case VideoQuality.medium720p:
        return (1280, 720);
      case VideoQuality.high1080p:
        return (1920, 1080);
    }
  }

  // ===== CAMERA CONTROL =====

  /// Switches between front and back camera.
  Future<void> switchCamera() async {
    _isFrontCamera = !_isFrontCamera;
    LoggerService.info('Camera switched: ${_isFrontCamera ? "front" : "back"}', tag: 'VideoCall');
  }

  /// Toggles video on/off (privacy mode).
  void toggleVideo() {
    _isVideoEnabled = !_isVideoEnabled;
    LoggerService.info('Video ${_isVideoEnabled ? "enabled" : "disabled"}', tag: 'VideoCall');
  }

  /// Toggles microphone mute.
  void toggleMute() {
    _isMuted = !_isMuted;
    LoggerService.info('Mute ${_isMuted ? "on" : "off"}', tag: 'VideoCall');
  }

  // ===== PICTURE-IN-PICTURE =====

  /// Enters Picture-in-Picture mode (minimized overlay).
  void enterPiP() {
    _isPiPMode = true;
    LoggerService.info('Entered PiP mode', tag: 'VideoCall');
  }

  /// Exits PiP mode.
  void exitPiP() {
    _isPiPMode = false;
    LoggerService.info('Exited PiP mode', tag: 'VideoCall');
  }

  // ===== STATE MANAGEMENT =====

  void _updateState(VideoCallState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  /// Starts a video call.
  Future<void> startVideoCall({
    required String callerNovaId,
    required String recipientNovaId,
  }) async {
    _updateState(VideoCallState.calling);
    LoggerService.info('Video call started: $callerNovaId → $recipientNovaId', tag: 'VideoCall');
  }

  /// Accepts an incoming video call.
  Future<void> acceptVideoCall({required String callId}) async {
    _updateState(VideoCallState.connected);
    LoggerService.info('Video call accepted: $callId', tag: 'VideoCall');
  }

  /// Ends the video call.
  Future<void> endVideoCall() async {
    _updateState(VideoCallState.ended);
    _isPiPMode = false;
    _isMuted = false;
    _isVideoEnabled = true;
    _isFrontCamera = true;
    _currentQuality = VideoQuality.medium720p;
    LoggerService.info('Video call ended', tag: 'VideoCall');
    _updateState(VideoCallState.idle);
  }

  /// Attempts to reconnect.
  Future<void> reconnect() async {
    _updateState(VideoCallState.reconnecting);
    LoggerService.info('Attempting video call reconnection', tag: 'VideoCall');
  }

  void dispose() {
    _stateController.close();
  }
}

final videoCallServiceProvider = Provider<VideoCallService>((ref) {
  final service = VideoCallService();
  ref.onDispose(() => service.dispose());
  return service;
});
