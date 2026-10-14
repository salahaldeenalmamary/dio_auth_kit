import 'dart:convert';

import 'package:dio/dio.dart';

/// What `AuthInterceptor` does with a failed response.
enum AuthErrorAction {
  /// Refresh the tokens and retry the request once.
  refresh,

  /// Clear the session and call `onSessionExpired`; no refresh.
  expireSession,

  /// Leave the session alone and return the error to the caller.
  passThrough,
}

/// Matches a backend error response and names the [action] to take.
///
/// Every condition given must hold; a rule with none matches any response.
/// Errors without a response (offline, timeouts) never match.
///
/// ```dart
/// AuthErrorRule.refreshOn({401, 419})
/// AuthErrorRule.refreshOn({401}, headerContains: {'www-authenticate': 'invalid_token'})
/// AuthErrorRule.expireOn({401, 404}, bodyContains: 'user not found')
/// AuthErrorRule.expireOn({403}, bodyFields: {'error.code': 'ACCOUNT_BLOCKED'})
/// AuthErrorRule.passThroughOn({401}, when: (e) => e.requestOptions.path == '/password')
/// ```
final class AuthErrorRule {
  const AuthErrorRule(
    this.action, {
    this.statuses,
    this.bodyFields,
    this.bodyContains,
    this.headerContains,
    this.when,
  });

  const AuthErrorRule.refreshOn(
    Set<int> statuses, {
    Map<String, Object?>? bodyFields,
    Pattern? bodyContains,
    Map<String, Pattern>? headerContains,
    bool Function(DioException error)? when,
  }) : this(
          AuthErrorAction.refresh,
          statuses: statuses,
          bodyFields: bodyFields,
          bodyContains: bodyContains,
          headerContains: headerContains,
          when: when,
        );

  const AuthErrorRule.expireOn(
    Set<int> statuses, {
    Map<String, Object?>? bodyFields,
    Pattern? bodyContains,
    Map<String, Pattern>? headerContains,
    bool Function(DioException error)? when,
  }) : this(
          AuthErrorAction.expireSession,
          statuses: statuses,
          bodyFields: bodyFields,
          bodyContains: bodyContains,
          headerContains: headerContains,
          when: when,
        );

  const AuthErrorRule.passThroughOn(
    Set<int> statuses, {
    Map<String, Object?>? bodyFields,
    Pattern? bodyContains,
    Map<String, Pattern>? headerContains,
    bool Function(DioException error)? when,
  }) : this(
          AuthErrorAction.passThrough,
          statuses: statuses,
          bodyFields: bodyFields,
          bodyContains: bodyContains,
          headerContains: headerContains,
          when: when,
        );

  final AuthErrorAction action;

  /// Status codes to match; `null` matches any status.
  final Set<int>? statuses;

  /// JSON body fields that must equal the given values. Keys may be dot
  /// paths into nested objects: `{'error.code': 'TOKEN_EXPIRED'}`.
  final Map<String, Object?>? bodyFields;

  /// Text the body must contain. A `String` matches case-insensitively; a
  /// `RegExp` is applied as given.
  final Pattern? bodyContains;

  /// Response headers that must contain the given text, such as
  /// `{'www-authenticate': 'invalid_token'}` (RFC 6750).
  final Map<String, Pattern>? headerContains;

  /// Any other condition.
  final bool Function(DioException error)? when;

  bool matches(DioException error) {
    final response = error.response;
    if (response == null) return false;

    final statuses = this.statuses;
    if (statuses != null && !statuses.contains(response.statusCode)) {
      return false;
    }

    final headerContains = this.headerContains;
    if (headerContains != null) {
      for (final MapEntry(:key, :value) in headerContains.entries) {
        final text = response.headers[key]?.join(', ') ?? '';
        if (!_contains(text, value)) return false;
      }
    }

    final bodyFields = this.bodyFields;
    if (bodyFields != null) {
      final body = _bodyMap(response.data);
      if (body == null) return false;
      for (final MapEntry(:key, :value) in bodyFields.entries) {
        final found = _lookup(body, key);
        if (!found.exists || found.value != value) return false;
      }
    }

    final bodyContains = this.bodyContains;
    if (bodyContains != null &&
        !_contains(_bodyText(response.data), bodyContains)) {
      return false;
    }

    return when?.call(error) ?? true;
  }

  static bool _contains(String text, Pattern pattern) => pattern is String
      ? text.toLowerCase().contains(pattern.toLowerCase())
      : text.contains(pattern);

  static String _bodyText(Object? data) {
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data, allowMalformed: true);
    if (data is Map || data is List) {
      try {
        return json.encode(data);
      } on Object {
        return data.toString();
      }
    }
    return data.toString();
  }

  static Map<Object?, Object?>? _bodyMap(Object? data) {
    if (data is Map) return data;
    if (data is String || data is List<int>) {
      try {
        final decoded = json.decode(_bodyText(data));
        return decoded is Map ? decoded : null;
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static ({bool exists, Object? value}) _lookup(
    Map<Object?, Object?> body,
    String path,
  ) {
    Object? current = body;
    for (final segment in path.split('.')) {
      if (current is! Map || !current.containsKey(segment)) {
        return (exists: false, value: null);
      }
      current = current[segment];
    }
    return (exists: true, value: current);
  }
}

/// The interceptor's global error rules, the widest scope.
///
/// Status sets from `@RefreshOn`, `@ExpireOn`, `@PassThroughOn` and
/// `AuthScope` are checked first; [rules] decide everything else.
final class AuthErrorPolicy {
  const AuthErrorPolicy({
    this.rules = const [
      AuthErrorRule.refreshOn({401})
    ],
    this.refreshFailure = const [
      AuthErrorRule.expireOn({400, 401, 403})
    ],
  });

  /// Rules for failed requests; the first match wins, no match passes the
  /// error through.
  final List<AuthErrorRule> rules;

  /// Rules for a failed refresh call: `expireSession` ends the session,
  /// anything else keeps the tokens (offline, 5xx). The first match wins.
  final List<AuthErrorRule> refreshFailure;

  /// The action of the first rule matching [error], or `null`.
  AuthErrorAction? actionFor(DioException error) {
    for (final rule in rules) {
      if (rule.matches(error)) return rule.action;
    }
    return null;
  }

  /// Whether a refresh that threw [error] means the session is gone.
  ///
  /// Errors other than [DioException], such as a malformed refresh response,
  /// always end the session.
  bool endsSession(Object error) {
    if (error is! DioException) return true;
    for (final rule in refreshFailure) {
      if (rule.matches(error)) {
        return rule.action == AuthErrorAction.expireSession;
      }
    }
    return false;
  }
}
