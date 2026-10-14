import 'package:meta/meta.dart';

import 'jwt.dart';

/// An access token and the optional refresh token that renews it.
@immutable
class TokenPair {
  const TokenPair({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;
  final String? refreshToken;

  /// Explicit access-token expiry. When `null`, the JWT `exp` claim is used.
  final DateTime? expiresAt;

  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  /// The access token's expiry, from [expiresAt] or the JWT `exp` claim.
  ///
  /// `null` means unknown; such a token is only refreshed after a 401.
  DateTime? get expiry => expiresAt ?? Jwt.tryExpiry(accessToken);

  /// Whether the access token expires within [leeway] of [now].
  bool isExpired({Duration leeway = Duration.zero, DateTime? now}) {
    final exp = expiry;
    if (exp == null) return false;
    return !(now ?? DateTime.now()).add(leeway).isBefore(exp);
  }

  TokenPair copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) =>
      TokenPair(
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  @override
  bool operator ==(Object other) =>
      other is TokenPair &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken, expiresAt);

  @override
  String toString() => 'TokenPair(accessToken: ${_mask(accessToken)}, '
      'refreshToken: ${_mask(refreshToken)}, expiresAt: $expiresAt)';

  static String _mask(String? token) =>
      token == null ? 'null' : '***${token.length}';
}
