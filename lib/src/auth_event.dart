import 'token_pair.dart';

/// Session changes made by `AuthInterceptor`.
sealed class AuthEvent {
  const AuthEvent();
}

/// A refresh succeeded and [tokens] were stored.
final class TokenRefreshed extends AuthEvent {
  const TokenRefreshed(this.tokens);

  final TokenPair tokens;
}

/// A refresh attempt threw. A [SessionExpired] follows when the error is a
/// rejection of the session rather than a transient failure.
final class RefreshFailed extends AuthEvent {
  const RefreshFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

/// The session ended and storage was cleared; the user must sign in again.
final class SessionExpired extends AuthEvent {
  const SessionExpired();
}
