import 'token_pair.dart';

/// Builds the headers that carry the access token.
typedef AuthHeaderBuilder = Map<String, String> Function(TokenPair tokens);

/// `Authorization: Bearer <access token>`.
Map<String, String> bearerHeader(TokenPair tokens) =>
    {'Authorization': 'Bearer ${tokens.accessToken}'};
