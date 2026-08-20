import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Participant in a group video call.
class VideoParticipant {
  final String novaId;
  final String displayName;
  bool isMuted;
  bool isVideoEnabled;
  bool isSpeaking;
  int bitrate;
  double frameRate;

  VideoParticipant({
    required this.novaId,
    required this.displayName,
    this.isMuted = false,
    this.isVideoEnabled = true,
    this.isSpeaking = false,
    this.bitrate = 500,
    this.frameRate = 30,
  });
}

/// Topology mode for group calls.
enum CallTopology { mesh, sfu }

/// Group video call service for FASE 11.
///
/// Supports:
///   - Mesh topology for 2-3 participants (P2P)
///   - SFU topology for 4+ participants (server relay)
///   - Dynamic grid layout
///   - Active speaker detection
///   - Permission controls (mute, video toggle, kick)

class GroupVideoCallService {
  final List<VideoParticipant> _participants = [];
  List<VideoParticipant> get participants => List.unmodifiable(_participants);

  CallTopology _topology = CallTopology.mesh;
  CallTopology get topology => _topology;

  String? _activeSpeakerId;
  String? get activeSpeakerId => _activeSpeakerId;

  bool _isGridMode = true;
  bool get isGridMode => _isGridMode;

  final StreamController<List<VideoParticipant>> _participantsController =
      StreamController<List<VideoParticipant>>.broadcast();
  Stream<List<VideoParticipant>> get onParticipantsChanged => _participantsController.stream;

  // ===== TOPOLOGY SELECTION =====

  /// Selects the appropriate topology based on participant count.
  void selectTopology(int participantCount) {
    if (participantCount <= 3) {
      _topology = CallTopology.mesh;
    } else {
      _topology = CallTopology.sfu;
    }
    LoggerService.info(
      'Topology selected: $_topology (${participantCount} participants)',
      tag: 'GroupVideo',
    );
  }

  // ===== PARTICIPANT MANAGEMENT =====

  /// Adds a participant to the call.
  void addParticipant(VideoParticipant participant) {
    _participants.add(participant);
    selectTopology(_participants.length);
    _participantsController.add(_participants);
    LoggerService.info('Participant added: ${participant.novaId}', tag: 'GroupVideo');
  }

  /// Removes a participant from the call.
  void removeParticipant(String novaId) {
    _participants.removeWhere((p) => p.novaId == novaId);
    selectTopology(_participants.length);
    _participantsController.add(_participants);

    if (_activeSpeakerId == novaId) {
      _activeSpeakerId = null;
      _detectActiveSpeaker();
    }
    LoggerService.info('Participant removed: $novaId', tag: 'GroupVideo');
  }

  /// Gets a participant by Nova ID.
  VideoParticipant? getParticipant(String novaId) {
    try {
      return _participants.firstWhere((p) => p.novaId == novaId);
    } catch (_) {
      return null;
    }
  }

  // ===== ACTIVE SPEAKER DETECTION =====

  /// Detects the active speaker based on audio levels.
  void _detectActiveSpeaker() {
    if (_participants.isEmpty) return;

    // Find the participant who is speaking and not muted
    final speakers = _participants.where((p) => p.isSpeaking && !p.isMuted).toList();
    if (speakers.isNotEmpty) {
      _activeSpeakerId = speakers.first.novaId;
    } else {
      _activeSpeakerId = null;
    }
  }

  /// Updates speaking state for a participant.
  void updateSpeakingState(String novaId, bool isSpeaking) {
    final participant = getParticipant(novaId);
    if (participant != null) {
      participant.isSpeaking = isSpeaking;
      _detectActiveSpeaker();
      _participantsController.add(_participants);
    }
  }

  // ===== GRID LAYOUT =====

  /// Toggles between grid mode and active speaker mode.
  void toggleLayoutMode() {
    _isGridMode = !_isGridMode;
    LoggerService.info('Layout mode: ${_isGridMode ? "grid" : "speaker"}', tag: 'GroupVideo');
  }

  /// Calculates grid dimensions for the given participant count.
  (int columns, int rows) getGridLayout(int count) {
    switch (count) {
      case 0: return (0, 0);
      case 1: return (1, 1);
      case 2: return (2, 1);
      case 3: return (2, 2); // 2x2 with one empty
      case 4: return (2, 2);
      case 5:
      case 6: return (3, 2);
      case 7:
      case 8:
      case 9: return (3, 3);
      default: return (4, 3); // Max 12 visible
    }
  }

  /// Returns the list of participants to display in the grid.
  /// Limits to 12 visible participants for performance.
  List<VideoParticipant> getVisibleParticipants({int maxVisible = 12}) {
    if (_isGridMode || _activeSpeakerId == null) {
      return _participants.take(maxVisible).toList();
    }

    // In speaker mode: active speaker + top 3 others
    final active = _participants.where((p) => p.novaId == _activeSpeakerId).toList();
    final others = _participants
        .where((p) => p.novaId != _activeSpeakerId)
        .take(3)
        .toList();

    return [...active, ...others];
  }

  // ===== PERMISSION CONTROLS =====

  /// Mutes a participant (admin only).
  Future<bool> muteParticipant({
    required String requesterNovaId,
    required String targetNovaId,
  }) async {
    if (!_hasAdminPermission(requesterNovaId)) return false;

    final target = getParticipant(targetNovaId);
    if (target != null) {
      target.isMuted = true;
      _participantsController.add(_participants);
      LoggerService.info('Muted: $targetNovaId', tag: 'GroupVideo');
      return true;
    }
    return false;
  }

  /// Kicks a participant (admin only).
  Future<bool> kickParticipant({
    required String requesterNovaId,
    required String targetNovaId,
  }) async {
    if (!_hasAdminPermission(requesterNovaId)) return false;

    removeParticipant(targetNovaId);
    LoggerService.info('Kicked: $targetNovaId', tag: 'GroupVideo');
    return true;
  }

  /// Checks if a participant has admin privileges.
  bool _hasAdminPermission(String novaId) {
    // In production, check group role from database
    return _participants.isNotEmpty && _participants.first.novaId == novaId;
  }

  // ===== STATE =====

  /// Resets the group call state.
  void reset() {
    _participants.clear();
    _activeSpeakerId = null;
    _isGridMode = true;
    _topology = CallTopology.mesh;
    _participantsController.add(_participants);
  }

  void dispose() {
    _participantsController.close();
  }
}

final groupVideoCallServiceProvider = Provider<GroupVideoCallService>((ref) {
  final service = GroupVideoCallService();
  ref.onDispose(() => service.dispose());
  return service;
});
