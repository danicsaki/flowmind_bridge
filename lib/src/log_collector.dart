part of flowmind_bridge;

/// Collects Flutter runtime logs for the QA agent.
class _LogCollector {
  final _buffer = <String>[];
  static const _maxLogs = 500;

  void attach() {
    // Override Flutter's error handler to capture errors
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _buffer.add('[FlutterError] ${details.exceptionAsString()}');
      if (_buffer.length > _maxLogs) _buffer.removeAt(0);
      originalOnError?.call(details);
    };

    // Capture zone errors
    runZonedGuarded(() {}, (error, stack) {
      _buffer.add('[ZoneError] $error\n$stack');
      if (_buffer.length > _maxLogs) _buffer.removeAt(0);
    });
  }

  /// Add a log message manually.
  void log(String message) {
    _buffer.add(message);
    if (_buffer.length > _maxLogs) _buffer.removeAt(0);
  }

  /// Drain and return all accumulated logs.
  List<String> drain() {
    final logs = List<String>.from(_buffer);
    _buffer.clear();
    return logs;
  }

  void clear() {
    _buffer.clear();
  }
}
