import 'package:dio/dio.dart';

import 'auth_extra.dart';

/// Auth settings for a whole client, between per-method annotations and the
/// interceptor's global defaults.
///
/// They travel as marker headers that `AuthInterceptor` removes before the
/// request is sent, because retrofit only accepts class-level settings as
/// `@RestApi(headers:)` (retrofit >= 4.8):
///
/// ```dart
/// @RestApi(headers: AuthScope.none)
/// abstract class PublicApi { ... }
///
/// @RestApi(headers: {...AuthScope.optional, ...AuthScope.skipRefresh})
/// abstract class CatalogApi { ... }
/// ```
///
/// On older retrofit, scope the client's Dio instead with [AuthScope.dio].
abstract final class AuthScope {
  static const modeHeader = 'x-dio-auth-kit-mode';
  static const skipRefreshHeader = 'x-dio-auth-kit-skip-refresh';

  static const required = {modeHeader: 'required'};
  static const optional = {modeHeader: 'optional'};
  static const none = {modeHeader: 'none'};
  static const skipRefresh = {skipRefreshHeader: 'true'};
  static const allowRefresh = {skipRefreshHeader: 'false'};

  /// The marker headers for [mode] and [skipRefresh].
  static Map<String, String> headers({AuthMode? mode, bool? skipRefresh}) => {
        if (mode != null) modeHeader: mode.name,
        if (skipRefresh != null) skipRefreshHeader: '$skipRefresh',
      };

  /// A Dio that shares [base]'s adapter, transformer and interceptors, with
  /// the client scope applied to every request:
  ///
  /// ```dart
  /// final public = PublicApi(AuthScope.dio(dio, mode: AuthMode.none));
  /// ```
  ///
  /// Interceptors added to [base] afterwards are not picked up.
  static Dio dio(Dio base, {AuthMode? mode, bool? skipRefresh}) {
    final scoped = Dio(
      base.options.copyWith(
        headers: {
          ...base.options.headers,
          ...headers(mode: mode, skipRefresh: skipRefresh),
        },
      ),
    )
      ..httpClientAdapter = base.httpClientAdapter
      ..transformer = base.transformer;
    scoped.interceptors
      ..clear(keepImplyContentTypeInterceptor: false)
      ..addAll(base.interceptors);
    return scoped;
  }

  /// Moves the marker headers out of [options] into its extras so they never
  /// reach the network. Safe to call more than once.
  static void absorb(RequestOptions options) {
    final headers = options.headers;
    for (final key in headers.keys.toList()) {
      final lower = key.toLowerCase();
      if (lower == modeHeader) {
        final mode = AuthMode.values.asNameMap()['${headers.remove(key)}'];
        if (mode != null) options.extra[AuthExtra.scopeMode] = mode.name;
      } else if (lower == skipRefreshHeader) {
        final value = '${headers.remove(key)}'.toLowerCase();
        if (value == 'true' || value == 'false') {
          options.extra[AuthExtra.scopeSkipRefresh] = value == 'true';
        }
      }
    }
  }
}
