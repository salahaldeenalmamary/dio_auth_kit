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
  static const mode = 'dio_auth_kit.mode';
  static const skipRefresh = 'dio_auth_kit.skipRefresh';

  /// Set on a retried request so a second 401 does not refresh again.
  static const retried = 'dio_auth_kit.retried';

  /// The access token the request was sent with.
  static const sentToken = 'dio_auth_kit.sentToken';

  /// The [AuthMode] stored in [options], or `null` when unset.
  static AuthMode? modeOf(RequestOptions options) {
    final value = options.extra[mode];
    return value is String ? AuthMode.values.asNameMap()[value] : null;
  }

  static bool skipsRefresh(RequestOptions options) =>
      options.extra[skipRefresh] == true;

  /// The extras for plain dio calls, the counterpart of the annotations.
  ///
  /// ```dart
  /// dio.post('/auth/login', options: AuthExtra.options(mode: AuthMode.none));
  /// ```
  static Options options({AuthMode? mode, bool skipRefresh = false}) =>
      Options(extra: extras(mode: mode, skipRefresh: skipRefresh));

  static Map<String, Object> extras({
    AuthMode? mode,
    bool skipRefresh = false,
  }) =>
      {
        if (mode != null) AuthExtra.mode: mode.name,
        if (skipRefresh) AuthExtra.skipRefresh: true,
      };
}
