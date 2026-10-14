import 'dart:async';

import 'package:dio/dio.dart';

import 'auth_errors.dart';
import 'auth_event.dart';
import 'auth_extra.dart';
import 'auth_header.dart';
import 'auth_scope.dart';
import 'refresh_coordinator.dart';
import 'token_pair.dart';
import 'token_storage.dart';

/// Exchanges [current] for new tokens. [refreshDio] has no `AuthInterceptor`,
/// so the call cannot recurse. Throw to signal failure.
///
/// A returned pair without a refresh token keeps the current refresh token.
typedef TokenRefresher = Future<TokenPair> Function(
  Dio refreshDio,
  TokenPair current,
);

/// Whether a failed request should trigger a refresh and retry.
bool defaultShouldRefresh(DioException error) =>
    error.response?.statusCode == 401;

/// Whether a refresh error means the session is gone (clear and sign out)
/// rather than a transient failure (keep the tokens, fail this request).
///
/// Connection errors, timeouts and 5xx responses keep the session.
bool defaultIsSessionRejection(Object error) {
  if (error is! DioException) return true;
  final status = error.response?.statusCode;
  return status == 400 || status == 401 || status == 403;
}

/// Attaches the access token and refreshes it on 401, one refresh at a time.
///
/// ```dart
/// final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
/// dio.interceptors.add(AuthInterceptor(
///   dio: dio,
///   storage: CachedTokenStorage(SecureTokenStorage()),
///   refresh: (refreshDio, current) async {
///     final res = await refreshDio.post<Map<String, dynamic>>(
///       '/auth/refresh',
///       data: {'refresh_token': current.refreshToken},
///     );
///     return TokenPair(
///       accessToken: res.data!['access_token'] as String,
///       refreshToken: res.data!['refresh_token'] as String?,
///     );
///   },
///   onSessionExpired: () => router.go('/login'),
/// ));
/// ```
///
/// Each setting resolves from the most specific scope:
/// 1. the method: `@NoAuth`, `@OptionalAuth`, `@Authenticated`,
///    `@SkipRefresh`, `@AllowRefresh`, or `AuthExtra.options` on plain dio;
/// 2. the client: `@RestApi(headers: AuthScope.none)` or `AuthScope.dio`;
/// 3. this interceptor: [defaultMode] and [defaultSkipRefresh].
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.dio,
    required this.storage,
    required this.refresh,
    Dio? refreshDio,
    this.headerBuilder = bearerHeader,
    this.shouldRefresh = defaultShouldRefresh,
    this.isSessionRejection = defaultIsSessionRejection,
    this.isSessionInvalid,
    this.proactiveLeeway = const Duration(seconds: 30),
    this.defaultMode = AuthMode.required,
    this.defaultSkipRefresh = false,
    this.onSessionExpired,
  }) : _refreshDio = refreshDio;

  /// The client this interceptor is installed on; failed requests are
  /// retried through it.
  final Dio dio;
  final TokenStorage storage;
  final TokenRefresher refresh;
  final AuthHeaderBuilder headerBuilder;
  final bool Function(DioException error) shouldRefresh;
  final bool Function(Object refreshError) isSessionRejection;

  /// Ends the session without refreshing, such as when the server reports a
  /// deleted or blocked user.
  final bool Function(DioException error)? isSessionInvalid;

  /// Refresh before sending when the token expires within this window;
  /// `null` refreshes only after a 401.
  final Duration? proactiveLeeway;

  /// Mode when neither the method nor the client sets one.
  final AuthMode defaultMode;

  /// Whether a 401 skips refreshing when neither the method nor the client
  /// says.
  final bool defaultSkipRefresh;

  /// Called once each time the session ends, after storage is cleared.
  final FutureOr<void> Function()? onSessionExpired;

  final Dio? _refreshDio;
  final _coordinator = RefreshCoordinator();
  final _events = StreamController<AuthEvent>.broadcast();
  String? _expiredToken;

  /// The client passed to [refresh]: [dio]'s options and adapter, without
  /// its interceptors.
  late final Dio refreshDio = _refreshDio ??
      (Dio(
        dio.options.copyWith(
          headers: Map.of(dio.options.headers)
            ..removeWhere(
              (key, _) =>
                  key.toLowerCase() == AuthScope.modeHeader ||
                  key.toLowerCase() == AuthScope.skipRefreshHeader,
            ),
        ),
      )..httpClientAdapter = dio.httpClientAdapter);

  Stream<AuthEvent> get events => _events.stream;

  Future<void> close() => _events.close();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    AuthScope.absorb(options);
    final mode = _modeOf(options);
    if (mode == AuthMode.none) return handler.next(options);

    var tokens = await _currentTokens();
    if (tokens != null &&
        mode == AuthMode.required &&
        !_skipsRefresh(options) &&
        _expiresSoon(tokens)) {
      try {
        tokens = await _refresh(tokens);
      } catch (_) {
        // A rejected session was cleared; a transient failure keeps the old
        // token, which the server may still accept.
        tokens = await storage.read();
      }
    }

    if (tokens == null || tokens.accessToken.isEmpty) {
      if (mode == AuthMode.optional) return handler.next(options);
      return handler.reject(
        DioException(
          requestOptions: options,
          error: const NoSessionError(),
          message: 'No auth session for ${options.method} ${options.path}',
        ),
      );
    }

    options.headers.addAll(headerBuilder(tokens));
    options.extra[AuthExtra.sentToken] = tokens.accessToken;
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final sent = options.extra[AuthExtra.sentToken];
    if (sent is! String || _modeOf(options) != AuthMode.required) {
      return handler.next(err);
    }

    if (isSessionInvalid?.call(err) ?? false) {
      await _expire(sent);
      return handler.next(err);
    }

    if (!shouldRefresh(err) ||
        _skipsRefresh(options) ||
        options.extra[AuthExtra.retried] == true) {
      return handler.next(err);
    }

    final TokenPair fresh;
    try {
      final stored = await _currentTokens();
      if (stored == null) return handler.next(err);
      if (stored.accessToken != sent) {
        // Another request already refreshed while this one was in flight.
        fresh = stored;
      } else if (!stored.canRefresh) {
        await _expire(sent);
        return handler.next(err);
      } else {
        fresh = await _refresh(stored);
      }
    } catch (_) {
      return handler.next(err);
    }

    try {
      handler.resolve(await _retry(options, fresh));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  AuthMode _modeOf(RequestOptions options) =>
      AuthExtra.modeOf(options) ?? defaultMode;

  bool _skipsRefresh(RequestOptions options) =>
      AuthExtra.skipsRefresh(options, fallback: defaultSkipRefresh);

  bool _expiresSoon(TokenPair tokens) {
    final leeway = proactiveLeeway;
    return leeway != null &&
        tokens.canRefresh &&
        tokens.isExpired(leeway: leeway);
  }

  /// The stored tokens, after any refresh in progress has settled.
  Future<TokenPair?> _currentTokens() async {
    final inFlight = _coordinator.inFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // The refresh's own caller handles its failure.
      }
    }
    return storage.read();
  }

  Future<TokenPair> _refresh(TokenPair current) => _coordinator.run(() async {
        try {
          var next = await refresh(refreshDio, current);
          if (!next.canRefresh && current.canRefresh) {
            next = TokenPair(
              accessToken: next.accessToken,
              refreshToken: current.refreshToken,
              expiresAt: next.expiresAt,
            );
          }
          await storage.write(next);
          _emit(TokenRefreshed(next));
          return next;
        } catch (error, stackTrace) {
          _emit(RefreshFailed(error, stackTrace));
          if (isSessionRejection(error)) await _expire(current.accessToken);
          rethrow;
        }
      });

  /// Clears the session once per access token, however many requests fail
  /// with it.
  Future<void> _expire(String accessToken) async {
    if (_expiredToken == accessToken) return;
    _expiredToken = accessToken;
    await storage.clear();
    _emit(const SessionExpired());
    await onSessionExpired?.call();
  }

  Future<Response<dynamic>> _retry(RequestOptions options, TokenPair tokens) {
    final data = options.data;
    return dio.fetch<dynamic>(
      options.copyWith(
        data: data is FormData ? data.clone() : data,
        headers: {...options.headers, ...headerBuilder(tokens)},
        extra: {...options.extra, AuthExtra.retried: true},
      ),
    );
  }

  void _emit(AuthEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
