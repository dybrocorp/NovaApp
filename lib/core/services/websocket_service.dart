import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'logger_service.dart';

/// WebSocket service with challenge-response authentication.
///
/// Auth flow:
///   1. Client connects to server
///   2. Server sends 'auth_challenge' with {challenge, challenge_id}
///   3. Client signs challenge with Ed25519 identity key
///   4. Client sends 'auth_response' with {challenge_id, signature, public_key, nova_id}
///   5. Server verifies signature, associates session, sends 'auth_success'
///   6. Only after 'auth_success' does the client send/receive real messages
class WebSocketService {
  IO.Socket? _socket;
  final String _serverUrl;
  String? _currentUserId;
  bool _authenticated = false;
  final Map<String, Function(dynamic)> _messageHandlers = {};
  final Map<String, Function()> _eventHandlers = {};
  final StreamController<Map<String, dynamic>> _messageStreamController = StreamController.broadcast();
  final StreamController<bool> _connectionStatusController = StreamController.broadcast();
  final StreamController<bool> _authStatusController = StreamController.broadcast();

  WebSocketService({String? serverUrl})
      : _serverUrl = serverUrl ?? dotenv.env['SOCKET_SERVER_URL'] ?? '';

  Stream<Map<String, dynamic>> get messageStream => _messageStreamController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  Stream<bool> get authStatusStream => _authStatusController.stream;

  bool get isConnected => _socket?.connected ?? false;
  bool get isAuthenticated => _authenticated;

  Future<void> connect(String userId, {
    SimpleKeyPair? identityKeyPair,
  }) async {
    if (_socket?.connected ?? false) {
      LoggerService.debug('Already connected', tag: 'WebSocket');
      return;
    }

    _currentUserId = userId;
    _authenticated = false;

    try {
      if (_serverUrl.isEmpty) {
        LoggerService.warning('SOCKET_SERVER_URL is not configured', tag: 'WebSocket');
        _connectionStatusController.add(false);
        return;
      }

      _socket = IO.io(_serverUrl, <String, dynamic>{
        'transports': ['websocket', 'polling'],
        'autoConnect': false,
        'reconnect': true,
        'reconnectAttempts': 10,
        'reconnectDelay': 1000,
        'reconnectDelayMax': 5000,
        'timeout': 20000,
      });

      _setupSocketListeners(identityKeyPair);
      
      _socket?.connect();
      LoggerService.info('Socket.io connecting to $_serverUrl', tag: 'WebSocket');
    } catch (e) {
      LoggerService.error('Connection error', error: e, tag: 'WebSocket');
      _connectionStatusController.add(false);
    }
  }

  void _setupSocketListeners(SimpleKeyPair? identityKeyPair) {
    if (_socket == null) return;

    _socket!.onConnect((_) {
      LoggerService.debug('Connected, awaiting auth challenge', tag: 'WebSocket');
      _connectionStatusController.add(true);
      // Do NOT emit anything until server sends auth_challenge
    });

    // Challenge-response authentication
    _socket!.on('auth_challenge', (data) async {
      LoggerService.debug('Auth challenge received', tag: 'WebSocket');
      if (identityKeyPair == null) {
        LoggerService.error('No identity key for auth', tag: 'WebSocket');
        _socket?.disconnect();
        return;
      }

      try {
        final challenge = data['challenge'] as String;
        final challengeId = data['challenge_id'] as String;

        // Sign challenge with Ed25519 identity key
        final signature = await Ed25519().sign(
          utf8.encode(challenge),
          keyPair: identityKeyPair,
        );
        final publicKey = await identityKeyPair.extractPublicKey();

        _socket!.emit('auth_response', {
          'challenge_id': challengeId,
          'signature': base64Encode(signature.bytes),
          'public_key': base64Encode(publicKey.bytes),
          'nova_id': _currentUserId,
        });

        LoggerService.debug('Auth response sent', tag: 'WebSocket');
      } catch (e) {
        LoggerService.error('Auth signing failed', error: e, tag: 'WebSocket');
        _socket?.disconnect();
      }
    });

    _socket!.on('auth_success', (_) {
      LoggerService.info('Authenticated successfully', tag: 'WebSocket');
      _authenticated = true;
      _authStatusController.add(true);
    });

    _socket!.on('auth_failure', (data) {
      LoggerService.error('Auth failed: $data', tag: 'WebSocket');
      _authenticated = false;
      _authStatusController.add(false);
      _socket?.disconnect();
    });

    _socket!.onDisconnect((_) {
      LoggerService.debug('Disconnected', tag: 'WebSocket');
      _authenticated = false;
      _connectionStatusController.add(false);
      _authStatusController.add(false);
    });

    _socket!.onConnectError((error) {
      LoggerService.error('Connection error', error: error, tag: 'WebSocket');
      _connectionStatusController.add(false);
    });

    _socket!.onError((error) {
      LoggerService.error('Error', error: error, tag: 'WebSocket');
    });

    _socket!.on('message', (data) {
      if (!_authenticated) return; // Reject until authenticated
      LoggerService.debug('Message received', tag: 'WebSocket');
      _messageStreamController.add(data);
      
      for (var handler in _messageHandlers.values) {
        try {
          handler(data);
        } catch (e) {
          LoggerService.error('Error in message handler', error: e, tag: 'WebSocket');
        }
      }
    });

    _socket!.on('typing', (data) {
      if (!_authenticated) return;
      LoggerService.debug('Typing indicator received', tag: 'WebSocket');
      for (var handler in _eventHandlers.values) {
        try {
          handler();
        } catch (e) {
          LoggerService.error('Error in event handler', error: e, tag: 'WebSocket');
        }
      }
    });

    _socket!.on('message_delivered', (data) {
      if (!_authenticated) return;
      LoggerService.debug('Message delivered', tag: 'WebSocket');
    });

    _socket!.on('message_read', (data) {
      if (!_authenticated) return;
      LoggerService.debug('Message read', tag: 'WebSocket');
    });

    _socket!.on('call_offer', (data) {
      if (!_authenticated) return;
      LoggerService.debug('Call offer received', tag: 'WebSocket');
    });

    _socket!.on('call_answer', (data) {
      if (!_authenticated) return;
      LoggerService.debug('Call answer received', tag: 'WebSocket');
    });

    _socket!.on('call_ice_candidate', (data) {
      if (!_authenticated) return;
      LoggerService.debug('ICE candidate received', tag: 'WebSocket');
    });

    _socket!.on('call_end', (data) {
      if (!_authenticated) return;
      LoggerService.debug('Call ended', tag: 'WebSocket');
    });
  }

  void sendMessage(String recipientId, Map<String, dynamic> message) {
    if (!(_socket?.connected ?? false) || !_authenticated) {
      LoggerService.warning('Not connected/authenticated, cannot send message', tag: 'WebSocket');
      return;
    }
    _socket!.emit('send_message', {
      'senderId': _currentUserId,
      'recipientId': recipientId,
      'message': message,
      'timestamp': DateTime.now().toIso8601String(),
    });
    LoggerService.debug('Message sent to $recipientId', tag: 'WebSocket');
  }

  void sendTypingIndicator(String recipientId, bool isTyping) {
    if (!(_socket?.connected ?? false) || !_authenticated) return;
    _socket!.emit('typing', {
      'senderId': _currentUserId,
      'recipientId': recipientId,
      'isTyping': isTyping,
    });
  }

  void markMessageAsRead(String messageId, String senderId) {
    if (!(_socket?.connected ?? false) || !_authenticated) return;
    _socket!.emit('mark_read', {
      'messageId': messageId,
      'senderId': senderId,
      'recipientId': _currentUserId,
    });
  }

  void sendCallOffer(String recipientId, Map<String, dynamic> offer, {bool isVideo = false}) {
    if (!(_socket?.connected ?? false) || !_authenticated) return;
    _socket!.emit('call_offer', {
      'callerId': _currentUserId,
      'recipientId': recipientId,
      'offer': offer,
      'isVideo': isVideo,
    });
  }

  void sendCallAnswer(String callerId, Map<String, dynamic> answer) {
    if (!(_socket?.connected ?? false) || !_authenticated) return;
    _socket!.emit('call_answer', {
      'calleeId': _currentUserId,
      'callerId': callerId,
      'answer': answer,
    });
  }

  void sendIceCandidate(String recipientId, Map<String, dynamic> candidate) {
    if (!(_socket?.connected ?? false) || !_authenticated) return;
    _socket!.emit('call_ice_candidate', {
      'senderId': _currentUserId,
      'recipientId': recipientId,
      'candidate': candidate,
    });
  }

  void endCall(String recipientId) {
    if (!(_socket?.connected ?? false) || !_authenticated) return;
    _socket!.emit('call_end', {
      'callerId': _currentUserId,
      'recipientId': recipientId,
    });
  }

  void onMessage(String eventType, Function(dynamic) handler) {
    _messageHandlers[eventType] = handler;
  }

  void onEvent(String eventType, Function() handler) {
    _eventHandlers[eventType] = handler;
  }

  void disconnect() {
    _authenticated = false;
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _connectionStatusController.add(false);
    _authStatusController.add(false);
    LoggerService.debug('Disconnected', tag: 'WebSocket');
  }

  void dispose() {
    disconnect();
    _messageStreamController.close();
    _connectionStatusController.close();
    _authStatusController.close();
  }
}

final webSocketServiceProvider = Provider<WebSocketService>((ref) {
  return WebSocketService();
});
