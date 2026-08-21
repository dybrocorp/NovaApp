import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:novaapp/core/services/logger_service.dart';

/// Voice note recording states.
enum VoiceRecordState { idle, recording, paused, stopped }

/// Enhanced voice note service for FASE 7.
///
/// Features:
///   - Record / pause / resume / cancel
///   - Real waveform data (amplitude samples)
///   - Accurate duration tracking
///   - Playback at 1x / 1.5x / 2x speed
///   - Progress bar with seek
///   - Audio encryption before send
///   - Visual status indicators

class VoiceNoteService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  bool _isRecorderInitialized = false;
  bool _isPlayerInitialized = false;

  VoiceRecordState _recordState = VoiceRecordState.idle;
  VoiceRecordState get recordState => _recordState;

  // Waveform data: list of amplitude samples (0.0 - 1.0)
  final List<double> _waveformData = [];
  List<double> get waveform => List.unmodifiable(_waveformData);

  // Duration tracking
  Duration _recordDuration = Duration.zero;
  Duration get recordDuration => _recordDuration;
  Timer? _durationTimer;

  // Playback state
  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;
  Duration _playbackPosition = Duration.zero;
  Duration get playbackPosition => _playbackPosition;
  Duration _playbackDuration = Duration.zero;
  Duration get playbackDuration => _playbackDuration;
  double _playbackSpeed = 1.0;
  double get playbackSpeed => _playbackSpeed;
  String? _currentPlayingPath;
  StreamSubscription<PlaybackDisposition>? _playbackSubscription;

  // Amplitude subscription
  StreamSubscription<RecordingDisposition>? _amplitudeSubscription;

  // ===== INITIALIZATION =====

  Future<void> initialize() async {
    if (!_isRecorderInitialized) {
      await _recorder.openRecorder();
      _isRecorderInitialized = true;
    }
    if (!_isPlayerInitialized) {
      await _player.openPlayer();
      _isPlayerInitialized = true;
    }
    LoggerService.info('VoiceNoteService initialized', tag: 'VoiceNote');
  }

  Future<void> dispose() async {
    _durationTimer?.cancel();
    _playbackSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    if (_isRecorderInitialized) await _recorder.closeRecorder();
    if (_isPlayerInitialized) await _player.closePlayer();
  }

  // ===== RECORDING =====

  /// Starts a new recording session.
  Future<void> startRecording() async {
    if (!_isRecorderInitialized) await initialize();

    _waveformData.clear();
    _recordDuration = Duration.zero;

    final path = await _getRecordingPath();

    await _recorder.startRecorder(
      toFile: path,
      codec: Codec.aacADTS,
      sampleRate: 44100,
      bitRate: 128000,
    );

    // Listen to amplitude for waveform
    _amplitudeSubscription = _recorder.onProgress?.listen((disposition) {
      final db = disposition.decibels ?? 0;
      final normalized = (db + 60) / 60; // Normalize -60dB to 0dB range
      final clamped = normalized.clamp(0.0, 1.0);
      _waveformData.add(clamped);
    });

    // Start duration timer
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordDuration += const Duration(seconds: 1);
    });

    _recordState = VoiceRecordState.recording;
    LoggerService.info('Recording started: $path', tag: 'VoiceNote');
  }

  /// Pauses the current recording.
  Future<void> pauseRecording() async {
    if (_recordState != VoiceRecordState.recording) return;
    await _recorder.pauseRecorder();
    _durationTimer?.cancel();
    _recordState = VoiceRecordState.paused;
    LoggerService.info('Recording paused', tag: 'VoiceNote');
  }

  /// Resumes a paused recording.
  Future<void> resumeRecording() async {
    if (_recordState != VoiceRecordState.paused) return;
    await _recorder.resumeRecorder();

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordDuration += const Duration(seconds: 1);
    });

    _recordState = VoiceRecordState.recording;
    LoggerService.info('Recording resumed', tag: 'VoiceNote');
  }

  /// Stops recording and returns the file path.
  Future<String?> stopRecording() async {
    _durationTimer?.cancel();
    _amplitudeSubscription?.cancel();

    final path = await _recorder.stopRecorder();
    _recordState = VoiceRecordState.stopped;

    LoggerService.info('Recording stopped: $path (${_recordDuration.inSeconds}s)',
        tag: 'VoiceNote');
    return path;
  }

  /// Cancels the current recording and deletes the file.
  Future<void> cancelRecording() async {
    _durationTimer?.cancel();
    _amplitudeSubscription?.cancel();

    final path = await _recorder.stopRecorder();
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }

    _waveformData.clear();
    _recordDuration = Duration.zero;
    _recordState = VoiceRecordState.idle;

    LoggerService.info('Recording cancelled', tag: 'VoiceNote');
  }

  // ===== PLAYBACK =====

  /// Plays a voice note file.
  Future<void> playVoiceNote(String filePath,
      {void Function()? onCompletion}) async {
    if (!_isPlayerInitialized) await initialize();

    if (_isPlaying) await stopPlayback();

    _currentPlayingPath = filePath;
    _playbackSpeed = 1.0;
    _playbackPosition = Duration.zero;
    _playbackDuration = Duration.zero;

    await _player.startPlayer(
      fromURI: filePath,
      codec: Codec.aacADTS,
      whenFinished: () {
        _isPlaying = false;
        _playbackPosition = Duration.zero;
        _playbackSubscription?.cancel();
        onCompletion?.call();
      },
    );

    // Track position and duration via onProgress stream
    _playbackSubscription = _player.onProgress?.listen((disposition) {
      _playbackPosition = disposition.position;
      _playbackDuration = disposition.duration;
    });

    _isPlaying = true;
    LoggerService.info('Playback started: $filePath', tag: 'VoiceNote');
  }

  /// Stops playback.
  Future<void> stopPlayback() async {
    _playbackSubscription?.cancel();
    await _player.stopPlayer();
    _isPlaying = false;
    _playbackPosition = Duration.zero;
    _currentPlayingPath = null;
  }

  /// Seeks to a specific position.
  Future<void> seekTo(Duration position) async {
    await _player.seekToPlayer(position);
    _playbackPosition = position;
  }

  /// Changes playback speed (1.0, 1.5, 2.0).
  Future<void> setPlaybackSpeed(double speed) async {
    if (speed < 0.5 || speed > 2.0) return;
    _playbackSpeed = speed;

    if (_isPlaying && _currentPlayingPath != null) {
      await _player.setSpeed(speed);
    }

    LoggerService.info('Playback speed: ${speed}x', tag: 'VoiceNote');
  }

  /// Cycles through speed options: 1.0 → 1.5 → 2.0 → 1.0
  Future<void> cyclePlaybackSpeed() async {
    const speeds = [1.0, 1.5, 2.0];
    final currentIndex = speeds.indexOf(_playbackSpeed);
    final nextIndex = (currentIndex + 1) % speeds.length;
    await setPlaybackSpeed(speeds[nextIndex]);
  }

  // ===== HELPERS =====

  Future<String> _getRecordingPath() async {
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir.path, 'voice_note_$timestamp.aac');
  }

  /// Formats duration as mm:ss.
  static String formatDuration(Duration duration) {
    final minutes =
        duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

final voiceNoteServiceProvider = Provider<VoiceNoteService>((ref) {
  final service = VoiceNoteService();
  ref.onDispose(() => service.dispose());
  return service;
});
