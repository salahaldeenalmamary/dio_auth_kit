import 'dart:async';

import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:test/test.dart';

class _SlowStorage implements TokenStorage {
  final reads = <Completer<TokenPair?>>[];
  TokenPair? written;

  @override
  Future<TokenPair?> read() {
    final completer = Completer<TokenPair?>();
    reads.add(completer);
    return completer.future;
  }

  @override
  Future<void> write(TokenPair tokens) async => written = tokens;

  @override
  Future<void> clear() async => written = null;
}

void main() {
  test('CachedTokenStorage reads the inner store once', () async {
    final inner = _SlowStorage();
    final cached = CachedTokenStorage(inner);

    final first = cached.read();
    final second = cached.read();
    inner.reads.single.complete(const TokenPair(accessToken: 'a'));

    expect((await first)?.accessToken, 'a');
    expect((await second)?.accessToken, 'a');
    expect((await cached.read())?.accessToken, 'a');
    expect(inner.reads, hasLength(1));
  });

  test('a write during the first read wins over the stale value', () async {
    final inner = _SlowStorage();
    final cached = CachedTokenStorage(inner);

    final pending = cached.read();
    await cached.write(const TokenPair(accessToken: 'new'));
    inner.reads.single.complete(const TokenPair(accessToken: 'old'));

    expect((await pending)?.accessToken, 'new');
    expect(inner.written?.accessToken, 'new');
  });

  test('clear empties the cache and the inner store', () async {
    final inner = _SlowStorage();
    final cached = CachedTokenStorage(inner);
    await cached.write(const TokenPair(accessToken: 'a'));
    await cached.clear();

    expect(await cached.read(), isNull);
    expect(inner.written, isNull);
  });
}
