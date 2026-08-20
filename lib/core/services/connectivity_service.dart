import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Connectivity monitoring service.
/// Tracks network state changes and notifies listeners.

enum ConnectivityState { online, offline, wifi, mobile }

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  final StreamController<ConnectivityState> _controller = StreamController<ConnectivityState>.broadcast();

  ConnectivityState _currentState = ConnectivityState.online;
  ConnectivityState get currentState => _currentState;

  /// Stream of connectivity state changes.
  Stream<ConnectivityState> get onConnectivityChanged => _controller.stream;

  /// Starts monitoring connectivity.
  void startMonitoring() {
    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      final newState = _mapResult(result);

      if (newState != _currentState) {
        _currentState = newState;
        _controller.add(newState);
        LoggerService.info('Connectivity changed: $newState', tag: 'Connectivity');
      }
    });

    // Check initial state
    _checkInitialStatus();
  }

  Future<void> _checkInitialStatus() async {
    try {
      final results = await _connectivity.checkConnectivity();
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      _currentState = _mapResult(result);
      _controller.add(_currentState);
    } catch (_) {}
  }

  ConnectivityState _mapResult(ConnectivityResult result) {
    switch (result) {
      case ConnectivityResult.wifi:
        return ConnectivityState.wifi;
      case ConnectivityResult.mobile:
        return ConnectivityState.mobile;
      case ConnectivityResult.ethernet:
        return ConnectivityState.online;
      case ConnectivityResult.vpn:
        return ConnectivityState.online;
      case ConnectivityResult.bluetooth:
        return ConnectivityState.offline;
      case ConnectivityResult.other:
        return ConnectivityState.online;
      case ConnectivityResult.none:
        return ConnectivityState.offline;
    }
  }

  bool get isOnline => _currentState != ConnectivityState.offline;
  bool get isWifi => _currentState == ConnectivityState.wifi;

  void stopMonitoring() {
    _subscription?.cancel();
  }

  void dispose() {
    stopMonitoring();
    _controller.close();
  }
}

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService();
  ref.onDispose(() => service.dispose());
  return service;
});
