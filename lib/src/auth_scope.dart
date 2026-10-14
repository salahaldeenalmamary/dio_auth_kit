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
/// Status rules take a comma-separated list:
///
/// ```dart
/// @RestApi(headers: {AuthScope.refreshOnHeader: '401,419'})
/// ```
///
/// On older retrofit, scope the client's Dio instead with [AuthScope.dio].
abstract final class AuthScope {
  /// Every marker header starts with this; all are removed before sending.
  static const headerPrefix = 'x-dio-auth-kit-';

  static const modeHeader = 'x-dio-auth-kit-mode';
  static const skipRefreshHeader = 'x-dio-auth-kit-skip-refresh';
  static const refreshOnHeader = 'x-dio-auth-kit-refresh-on';
  static const expireOnHeader = 'x-dio-auth-kit-expire-on';
  static const passThroughOnHeader = 'x-dio-auth-kit-pass-through-on';

  static const required = {modeHeader: 'required'};
  static const optional = {modeHeader: 'optional'};
  static const none = {modeHeader: 'none'};
  static const skipRefresh = {skipRefreshHeader: 'true'};
  static const allowRefresh = {skipRefreshHeader: 'false'};

  /// The marker headers for the given settings.
  static Map<String, String> headers({
    AuthMode? mode,
    bool? skipRefresh,
    Set<int>? refreshOn,
    Set<int>? expireOn,
    Set<int>? passThroughOn,
  }) =>
      {
        if (mode != null) modeHeader: mode.name,
        if (skipRefresh != null) skipRefreshHeader: '$skipRefresh',
        if (refreshOn != null) refreshOnHeader: refreshOn.join(','),
        if (expireOn != null) expireOnHeader: expireOn.join(','),
        if (passThroughOn != null) passThroughOnHeader: passThroughOn.join(','),
      };

  /// Whether [name] is one of the marker headers.
  static bool isMarker(String name) =>
      name.toLowerCase().startsWith(headerPrefix);

  /// A Dio that shares [base]'s adapter, transformer and interceptors, with
  /// the client scope applied to every request:
  ///
  /// ```dart
  /// final public = PublicApi(AuthScope.dio(dio, mode: AuthMode.none));
  /// ```
  ///
  /// Interceptors added to [base] afterwards are not picked up.
  static Dio dio(
    Dio base, {
    AuthMode? mode,
    bool? skipRefresh,
    Set<int>? refreshOn,
    Set<int>? expireOn,
    Set<int>? passThroughOn,
  }) {
    final scoped = Dio(
      base.options.copyWith(
        headers: {
          ...base.options.headers,
          ...headers(
            mode: mode,
            skipRefresh: skipRefresh,
            refreshOn: refreshOn,
            expireOn: expireOn,
            passThroughOn: passThroughOn,
          ),
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
    final extra = options.extra;
    for (final key in headers.keys.where(isMarker).toList()) {
      final value = '${headers.remove(key)}'.trim();
      switch (key.toLowerCase()) {
        case modeHeader:
          final mode = AuthMode.values.asNameMap()[value];
          if (mode != null) extra[AuthExtra.scopeMode] = mode.name;
        case skipRefreshHeader:
          final flag = value.toLowerCase();
          if (flag == 'true' || flag == 'false') {
            extra[AuthExtra.scopeSkipRefresh] = flag == 'true';
          }
        case refreshOnHeader:
          extra[AuthExtra.scopeRefreshOn] =
              AuthExtra.statusesOf(value).toList();
        case expireOnHeader:
          extra[AuthExtra.scopeExpireOn] = AuthExtra.statusesOf(value).toList();
        case passThroughOnHeader:
          extra[AuthExtra.scopePassThroughOn] =
              AuthExtra.statusesOf(value).toList();
      }
    }
  }
}
