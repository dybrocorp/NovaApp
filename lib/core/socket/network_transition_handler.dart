/// Network-transition state machine (WiFi <-> mobile data, loss, regain).
///
/// Behavior (spec FASE 0.5 PASO 4 §6-7):
///   * On disconnect (not user-initiated): enter reconnecting with backoff.
///   * On connectivity REGAINED after a real outage: trigger an immediate
///     reconnect attempt (don't wait out the remaining backoff), reset the
///     backoff attempt counter (the cause was external), and after
///     re-authentication always request a SYNC of missed events.
///   * On connectivity CHANGED while connected (WiFi -> mobile or
///     mobile -> WiFi): the old socket frequently goes half-open; force a
///     graceful disconnect + immediate reconnect + re-auth + resync.
///   * No blind reuse of the old session: every new connection runs a full
///     handshake (new challenge, new signature, new session).
enum ConnectivityDecision {
  none, // nothing to do
  reconnectNow, // schedule immediate reconnect (reset backoff)
  forceDisconnectAndReconnect, // connected but transport changed: recycle
}

class NetworkTransitionHandler {
  bool _wasOffline = false;
  String? _lastNetworkKind;
  bool _resyncPending = false;

  /// Feeds a connectivity snapshot: [online] and the current [networkKind]
  /// ('wifi', 'mobile', 'ethernet', ...). Returns the decision.
  ConnectivityDecision onConnectivityChanged({
    required bool online,
    required String networkKind,
    required bool socketConnected,
  }) {
    if (!online) {
      _wasOffline = true;
      return ConnectivityDecision.none;
    }

    final regainedAfterOutage = _wasOffline;
    final previousKind = _lastNetworkKind;
    _wasOffline = false;
    _lastNetworkKind = networkKind;

    if (regainedAfterOutage) {
      // Internet came back after being lost: reconnect immediately, even if
      // the socket still LOOKS alive — after an outage it often lies.
      return socketConnected
          ? ConnectivityDecision.forceDisconnectAndReconnect
          : ConnectivityDecision.reconnectNow;
    }

    final kindChanged = previousKind != null && previousKind != networkKind;
    if (kindChanged) {
      // WiFi -> mobile (or mobile -> WiFi) without going fully offline.
      // The old transport is suspect: recycle the connection.
      return socketConnected
          ? ConnectivityDecision.forceDisconnectAndReconnect
          : ConnectivityDecision.reconnectNow;
    }
    return ConnectivityDecision.none;
  }

  /// Whether the current connection cycle requires a sync.request right
  /// after re-authentication (reconnect caused by network loss/switch or
  /// server-side disconnect).
  bool get requiresResync => _resyncPending;

  /// Marks that the next successful auth must be followed by sync.request.
  void markResyncNeeded() => _resyncPending = true;

  /// Clears the resync flag (after sync.response is handled).
  void resyncCompleted() => _resyncPending = false;
}
