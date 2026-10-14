import 'dart:convert';

/// Minimal, dependency-free JWT payload reader.
///
/// It does **not** verify signatures. It only reads claims, such as `exp`, so
/// the client can decide when to refresh. The server stays the authority.
abstract final class Jwt {
  /// The decoded payload, or `null` when [token] is not a well-formed JWT.
  static Map<String, Object?>? tryDecodePayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3 || parts[1].isEmpty) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(parts[1]));
      final decoded = json.decode(utf8.decode(bytes));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// The `exp` claim as a UTC [DateTime], or `null` when absent or unreadable.
  static DateTime? tryExpiry(String token) {
    final exp = tryDecodePayload(token)?['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (exp * 1000).round(),
      isUtc: true,
    );
  }
}
