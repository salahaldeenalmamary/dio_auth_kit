import 'token_pair.dart';

/// Runs at most one refresh at a time; concurrent callers share its result.
class RefreshCoordinator {
  Future<TokenPair>? _inFlight;

  /// The refresh in progress, if any.
  Future<TokenPair>? get inFlight => _inFlight;

  /// Joins the refresh in progress, or starts [refresh] when none is running.
  Future<TokenPair> run(Future<TokenPair> Function() refresh) {
    final existing = _inFlight;
    if (existing != null) return existing;

    final future = Future.sync(refresh);
    _inFlight = future;
    // Cleared only after completion, so every caller that joined while it
    // ran has already attached to the same future.
    void clear() {
      if (identical(_inFlight, future)) _inFlight = null;
    }

    future.then((_) => clear(), onError: (Object _) => clear());
    return future;
  }
}
