import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'logger_service.dart';

class WebSocketService {
  IO.Socket? _socket;
  final String _serverUrl;
  String? _currentUserId;
  final Map<String, Function(dynamic)> _messageHandlers = {};
  final Map<String, Function()> _eventHandlers = {};
  final StreamController<Map<String, dynamic>> _messageStreamController = StreamController.broadcast();
  final StreamController<bool> _connectionStatusController = StreamController.broadcast();

  WebSocketService({String? serverUrl})
      : _serverUrl = serverUrl ?? dotenv.env['SOCKET_SERVER_URL'] ?? '';

  Stream<Map<String, dynamic>> get messageStream => _messageStreamController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;

  bool get isConnected => _socket?.connected ?? false;

  Future<void> connect(String userId) async {
    if (_socket?.connected ?? false) {
      LoggerService.debug('Already connected', tag: 'WebSocket');
      return;
    }

    _currentUserId = userId;

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

      _setupSocketListeners();
      
      _socket?.connect();
      LoggerService.info('Socket.io connecting to $_serverUrl', tag: 'WebSocket');
    } catch (e) {
      LoggerService.error('Connection error', error: e, tag: 'WebSocket');
      _connectionStatusController.add(false);
    }
  }

  void _setupSocketListeners() {
    if (_socket == null) return;

    _socket!.onConnect((_) {
      LoggerService.debug('Connected', tag: 'WebSocket');
      _socket!.emit('authenticate', {'userId': _currentUserId});
      _connectionStatusController.add(true);
    });

    _socket!.onDisconnect((_) {
      LoggerService.debug('Disconnected', tag: 'WebSocket');
      _connectionStatusController.add(false);
    });

    _socket!.onConnectError((error) {
      LoggerService.error('Connection error', error: error, tag: 'WebSocket');
      _connectionStatusController.add(false);
    });

    _socket!.onError((error) {
      LoggerService.error('Error', error: error, tag: 'WebSocket');
    });

    _socket!.on('message', (data) {
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
      LoggerService.debug('Message delivered', tag: 'WebSocket');
    });

    _socket!.on('message_read', (data) {
      LoggerService.debug('Message read', tag: 'WebSocket');
    });

    _socket!.on('call_offer', (data) {
      LoggerService.debug('Call offer received', tag: 'WebSocket');
    });

    _socket!.on('call_answer', (data) {
      LoggerService.debug('Call answer received', tag: 'WebSocket');
    });

    _socket!.on('call_ice_candidate', (data) {
      LoggerService.debug('ICE candidate received', tag: 'WebSocket');
    });

    _socket!.on('call_end', (data) {
      LoggerService.debug('Call ended', tag: 'WebSocket');
    });
  }

  void sendMessage(String recipientId, Map<String, dynamic> message) {
    if (_socket?.connected ?? false) {
      _socket!.emit('send_message', {
        'senderId': _currentUserId,
        'recipientId': recipientId,
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
      });
      LoggerService.debug('Message sent to $recipientId', tag: 'WebSocket');
    } else {
      LoggerService.warning('Not connected, cannot send message', tag: 'WebSocket');
    }
  }

  void sendTypingIndicator(String recipientId, bool isTyping) {
    if (_socket?.connected ?? false) {
      _socket!.emit('typing', {
        'senderId': _currentUserId,
        'recipientId': recipientId,
        'isTyping': isTyping,
      });
    }
  }

  void markMessageAsRead(String messageId, String senderId) {
    if (_socket?.connected ?? false) {
      _socket!.emit('mark_read', {
        'messageId': messageId,
        'senderId': senderId,
        'recipientId': _currentUserId,
      });
    }
  }

  void sendCallOffer(String recipientId, Map<String, dynamic> offer, {bool isVideo = false}) {
    if (_socket?.connected ?? false) {
      _socket!.emit('call_offer', {
        'callerId': _currentUserId,
        'recipientId': recipientId,
        'offer': offer,
        'isVideo': isVideo,
      });
    }
  }

  void sendCallAnswer(String callerId, Map<String, dynamic> answer) {
    if (_socket?.connected ?? false) {
      _socket!.emit('call_answer', {
        'calleeId': _currentUserId,
        'callerId': callerId,
        'answer': answer,
      });
    }
  }

  void sendIceCandidate(String recipientId, Map<String, dynamic> candidate) {
    if (_socket?.connected ?? false) {
      _socket!.emit('call_ice_candidate', {
        'senderId': _currentUserId,
        'recipientId': recipientId,
        'candidate': candidate,
      });
    }
  }

  void endCall(String recipientId) {
    if (_socket?.connected ?? false) {
      _socket!.emit('call_end', {
        'callerId': _currentUserId,
        'recipientId': recipientId,
      });
    }
  }

  void onMessage(String eventType, Function(dynamic) handler) {
    _messageHandlers[eventType] = handler;
  }

  void onEvent(String eventType, Function() handler) {
    _eventHandlers[eventType] = handler;
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _connectionStatusController.add(false);
    LoggerService.debug('Disconnected', tag: 'WebSocket');
  }

  void dispose() {
    disconnect();
    _messageStreamController.close();
    _connectionStatusController.close();
  }
}

final webSocketServiceProvider = Provider<WebSocketService>((ref) {
  return WebSocketService();
});
