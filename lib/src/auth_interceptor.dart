import 'dart:async';

import 'package:dio/dio.dart';

import 'auth_error_policy.dart';
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
///
/// What a failed response triggers (refresh, end the session or pass
/// through) resolves the same way: `@RefreshOn`/`@ExpireOn`/`@PassThroughOn`,
/// then the client's `AuthScope` status headers, then [errorPolicy].
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.dio,
    required this.storage,
    required this.refresh,
    Dio? refreshDio,
    this.headerBuilder = bearerHeader,
    this.errorPolicy = const AuthErrorPolicy(),
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

  /// Global rules for failed responses and failed refresh calls.
  final AuthErrorPolicy errorPolicy;

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
            ..removeWhere((key, _) => AuthScope.isMarker(key)),
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
    final mode = _modeOf(options);
    if (sent is! String || mode == AuthMode.none) return handler.next(err);

    switch (_actionFor(err)) {
      case AuthErrorAction.expireSession:
        // Any request that carried the token, optional ones included.
        await _expire(sent);
        return handler.next(err);
      case AuthErrorAction.refresh
          when mode == AuthMode.required &&
              !_skipsRefresh(options) &&
              options.extra[AuthExtra.retried] != true:
        break;
      default:
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

  AuthErrorAction? _actionFor(DioException err) {
    final status = err.response?.statusCode;
    if (status == null) return null;
    return AuthExtra.statusActionOf(err.requestOptions, status) ??
        errorPolicy.actionFor(err);
  }

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
          if (errorPolicy.endsSession(error)) {
            await _expire(current.accessToken);
          }
          rethrow;
        }
      });

  /// Clears the session once per access token, however many requests fail
  /// with it, unless the token was already replaced by a refresh.
  Future<void> _expire(String accessToken) async {
    if (_expiredToken == accessToken) return;
    _expiredToken = accessToken;
    final stored = await storage.read();
    if (stored == null || stored.accessToken != accessToken) return;
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
