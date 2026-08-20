import 'package:flutter/foundation.dart';

enum LogLevel { trace, debug, info, warning, error }

class LoggerService {
  static const String _prefix = '[NovaApp]';

  /// Controls the minimum log level in release builds.
  /// In debug: all levels shown. In release: only warning+.
  static LogLevel _minLevel = kDebugMode ? LogLevel.trace : LogLevel.warning;

  static void setMinLevel(LogLevel level) => _minLevel = level;

  static void _log(
    LogLevel level,
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index < _minLevel.index) return;

    final fullTag = tag != null ? '$_prefix[$tag]' : _prefix;
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    debugPrint('$timestamp $fullTag ${level.name.toUpperCase()}: $message');
    if (error != null && kDebugMode) {
      debugPrint('  Error: $error');
    }
    if (stackTrace != null && kDebugMode) {
      debugPrint('  Stack: $stackTrace');
    }
  }

  static void trace(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.trace, message, tag: tag, error: error, stackTrace: stackTrace);

  static void debug(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.debug, message, tag: tag, error: error, stackTrace: stackTrace);

  static void info(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.info, message, tag: tag, error: error, stackTrace: stackTrace);

  static void warning(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.warning, message, tag: tag, error: error, stackTrace: stackTrace);

  static void error(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.error, message, tag: tag, error: error, stackTrace: stackTrace);
}
