import 'package:dio/dio.dart';

/// How a request uses the session.
enum AuthMode {
  /// Attach the token, refresh on 401, and fail fast without a session.
  required,

  /// Attach the token when one exists; never refresh, never fail for it.
  optional,

  /// Never attach a token (login, register, public endpoints).
  none,
}

/// `RequestOptions.extra` keys read by `AuthInterceptor`.
abstract final class AuthExtra {
  /// Method-level mode, written by the annotations.
  static const mode = 'dio_auth_kit.mode';

  /// Method-level refresh switch, written by `@SkipRefresh`/`@AllowRefresh`.
  static const skipRefresh = 'dio_auth_kit.skipRefresh';

  /// Client-level mode, absorbed from the `AuthScope` marker header.
  static const scopeMode = 'dio_auth_kit.scopeMode';

  /// Client-level refresh switch, absorbed from the `AuthScope` marker header.
  static const scopeSkipRefresh = 'dio_auth_kit.scopeSkipRefresh';

  /// Set on a retried request so a second 401 does not refresh again.
  static const retried = 'dio_auth_kit.retried';

  /// The access token the request was sent with.
  static const sentToken = 'dio_auth_kit.sentToken';

  /// The method-level [AuthMode], else the client-level one, else `null`.
  static AuthMode? modeOf(RequestOptions options) =>
      _mode(options.extra[mode]) ?? _mode(options.extra[scopeMode]);

  /// Whether a 401 skips refreshing: the method-level setting, else the
  /// client-level one, else [fallback].
  static bool skipsRefresh(RequestOptions options, {bool fallback = false}) {
    final method = options.extra[skipRefresh];
    if (method is bool) return method;
    final scope = options.extra[scopeSkipRefresh];
    if (scope is bool) return scope;
    return fallback;
  }

  static AuthMode? _mode(Object? value) =>
      value is String ? AuthMode.values.asNameMap()[value] : null;

  /// The extras for plain dio calls, the counterpart of the annotations.
  ///
  /// ```dart
  /// dio.post('/auth/login', options: AuthExtra.options(mode: AuthMode.none));
  /// ```
  static Options options({AuthMode? mode, bool? skipRefresh}) =>
      Options(extra: extras(mode: mode, skipRefresh: skipRefresh));

  static Map<String, Object> extras({AuthMode? mode, bool? skipRefresh}) => {
        if (mode != null) AuthExtra.mode: mode.name,
        if (skipRefresh != null) AuthExtra.skipRefresh: skipRefresh,
      };
}
