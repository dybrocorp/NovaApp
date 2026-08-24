/// Heartbeat watchdog: detects dead connections without extra traffic.
///
/// engine.io (Socket.IO transport) already runs a protocol-level ping/pong:
/// the server pings every `pingInterval` (recommended 25s) and drops the
/// socket if no pong arrives within `pingTimeout` (recommended 20s). The
/// client answers pings automatically — no app-level pings are needed, and
/// sending our own would waste battery.
///
/// What the client still needs to do is detect HALF-OPEN/dead connections
/// that the transport has not noticed yet (common on mobile network
/// switching). This watchdog tracks the timestamp of the last inbound packet
/// and force-closes the socket after [silenceThreshold] of silence.
///
/// Default threshold 75s = 25s pingInterval + 20s pingTimeout + 30s safety
/// margin. Check interval 15s: cheap timer, zero packets.
enum HeartbeatAction { none, disconnectDeadConnection }

class HeartbeatWatchdog {
  HeartbeatWatchdog({
    required this.silenceThreshold,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration silenceThreshold;
  final DateTime Function() _clock;

  DateTime? _lastActivity;

  /// Registers any inbound activity (any event, pong-equivalent, packet).
  /// Never logs content — only the timestamp matters.
  void noteActivity() => _lastActivity = _clock();

  /// Called by the periodic check timer.
  HeartbeatAction evaluate() {
    final last = _lastActivity;
    if (last == null) return HeartbeatAction.none;
    final silence = _clock().difference(last);
    if (silence > silenceThreshold) {
      _lastActivity = null; // Arm only after a fresh connection.
      return HeartbeatAction.disconnectDeadConnection;
    }
    return HeartbeatAction.none;
  }

  /// Clears state after a disconnect so the watchdog re-arms cleanly.
  void reset() => _lastActivity = null;

  /// Pure helper (used by tests and by the service) — a connection is dead
  /// when `silence > silenceThreshold`.
  bool isDead({required DateTime lastActivity, required DateTime now}) =>
      now.difference(lastActivity) > silenceThreshold;
}
