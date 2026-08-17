import 'package:flutter/foundation.dart';

class LoggerService {
  static const String _prefix = '[NovaApp]';

  static void info(String message, {String? tag, Object? error, StackTrace? stackTrace}) {
    final fullTag = tag != null ? '$_prefix[$tag]' : _prefix;
    debugPrint('$fullTag INFO: $message');
    if (error != null) {
      debugPrint('Error details: $error');
    }
    if (stackTrace != null) {
      debugPrint('Stack trace: $stackTrace');
    }
  }

  static void debug(String message, {String? tag, Object? error, StackTrace? stackTrace}) {
    final fullTag = tag != null ? '$_prefix[$tag]' : _prefix;
    debugPrint('$fullTag DEBUG: $message');
    if (error != null) {
      debugPrint('Error details: $error');
    }
    if (stackTrace != null) {
      debugPrint('Stack trace: $stackTrace');
    }
  }

  static void warning(String message, {String? tag, Object? error, StackTrace? stackTrace}) {
    final fullTag = tag != null ? '$_prefix[$tag]' : _prefix;
    debugPrint('$fullTag WARNING: $message');
    if (error != null) {
      debugPrint('Error details: $error');
    }
    if (stackTrace != null) {
      debugPrint('Stack trace: $stackTrace');
    }
  }

  static void error(String message, {String? tag, Object? error, StackTrace? stackTrace}) {
    final fullTag = tag != null ? '$_prefix[$tag]' : _prefix;
    debugPrint('$fullTag ERROR: $message');
    if (error != null) {
      debugPrint('Error details: $error');
    }
    if (stackTrace != null) {
      debugPrint('Stack trace: $stackTrace');
    }
  }

  static void trace(String message, {String? tag, Object? error, StackTrace? stackTrace}) {
    final fullTag = tag != null ? '$_prefix[$tag]' : _prefix;
    debugPrint('$fullTag TRACE: $message');
    if (error != null) {
      debugPrint('Error details: $error');
    }
    if (stackTrace != null) {
      debugPrint('Stack trace: $stackTrace');
    }
  }
}
