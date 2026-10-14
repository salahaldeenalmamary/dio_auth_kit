import 'token_pair.dart';

/// Where the current session's tokens live.
///
/// Implement this over `flutter_secure_storage`, shared preferences or any
/// other store; wrap slow stores in [CachedTokenStorage].
abstract interface class TokenStorage {
  Future<TokenPair?> read();
  Future<void> write(TokenPair tokens);
  Future<void> clear();
}

/// Process-local storage; tokens are lost when the process ends.
class InMemoryTokenStorage implements TokenStorage {
  InMemoryTokenStorage([this._tokens]);

  TokenPair? _tokens;

  @override
  Future<TokenPair?> read() async => _tokens;

  @override
  Future<void> write(TokenPair tokens) async => _tokens = tokens;

  @override
  Future<void> clear() async => _tokens = null;
}

/// Keeps the last known tokens in memory so each request avoids a slow
/// platform read. Writes and clears go through to [inner].
class CachedTokenStorage implements TokenStorage {
  CachedTokenStorage(this.inner);

  final TokenStorage inner;

  TokenPair? _cache;
  bool _loaded = false;
  Future<TokenPair?>? _loading;

  @override
  Future<TokenPair?> read() async {
    if (_loaded) return _cache;
    final value = await (_loading ??= inner.read());
    // A write or clear that landed while loading wins over the stale read.
    if (!_loaded) {
      _cache = value;
      _loaded = true;
    }
    return _cache;
  }

  @override
  Future<void> write(TokenPair tokens) {
    _cache = tokens;
    _loaded = true;
    return inner.write(tokens);
  }

  @override
  Future<void> clear() {
    _cache = null;
    _loaded = true;
    return inner.clear();
  }
}
