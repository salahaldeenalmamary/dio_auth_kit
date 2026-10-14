import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

const _stale = TokenPair(accessToken: 'a1', refreshToken: 'r1');
const _fresh = TokenPair(accessToken: 'a2', refreshToken: 'r2');

class _Harness {
  _Harness({
    TokenPair? stored = _stale,
    Route? route,
    TokenRefresher? refresh,
    Duration? proactiveLeeway = const Duration(seconds: 30),
    AuthMode defaultMode = AuthMode.required,
    bool Function(DioException)? isSessionInvalid,
  }) : storage = InMemoryTokenStorage(stored) {
    server = FakeServer(route ?? FakeServer.acceptTokens({'a2'}));
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = server;
    interceptor = AuthInterceptor(
      dio: dio,
      storage: storage,
      refresh: refresh ?? _countingRefresh,
      proactiveLeeway: proactiveLeeway,
      defaultMode: defaultMode,
      isSessionInvalid: isSessionInvalid,
      onSessionExpired: () => sessionExpired++,
    );
    interceptor.events.listen(events.add);
    dio.interceptors.add(interceptor);
  }

  final InMemoryTokenStorage storage;
  late final FakeServer server;
  late final Dio dio;
  late final AuthInterceptor interceptor;
  final events = <AuthEvent>[];
  var refreshCalls = 0;
  var sessionExpired = 0;

  Future<TokenPair> _countingRefresh(Dio _, TokenPair current) async {
    refreshCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return _fresh;
  }

  List<Object?> get sentAuth =>
      [for (final r in server.requests) r.headers['Authorization']];
}

void main() {
  test('attaches the bearer header', () async {
    final h = _Harness(stored: _fresh);
    final res = await h.dio.get<dynamic>('/me');

    expect(res.statusCode, 200);
    expect(h.sentAuth, ['Bearer a2']);
    expect(h.refreshCalls, 0);
  });

  test('NoAuth sends no header even with a session', () async {
    final h = _Harness(route: (_) => json(200, {}));
    await h.dio.post<dynamic>(
      '/auth/login',
      options: AuthExtra.options(mode: AuthMode.none),
    );

    expect(h.sentAuth, [null]);
  });

  test('required without a session fails before the network', () async {
    final h = _Harness(stored: null);

    await expectLater(
      h.dio.get<dynamic>('/me'),
      throwsA(
        isA<DioException>()
            .having((e) => e.error, 'error', isA<NoSessionError>()),
      ),
    );
    expect(h.server.requests, isEmpty);
  });

  test('optional auth attaches when present and never refreshes', () async {
    final h = _Harness();
    final optional = AuthExtra.options(mode: AuthMode.optional);

    await expectLater(
      h.dio.get<dynamic>('/catalog', options: optional),
      throwsA(isA<DioException>()),
    );
    expect(h.sentAuth, ['Bearer a1']);
    expect(h.refreshCalls, 0);

    await h.storage.clear();
    h.server.route = (_) => json(200, {});
    await h.dio.get<dynamic>('/catalog', options: optional);
    expect(h.sentAuth.last, isNull);
  });

  test('defaultMode applies to requests without an annotation', () async {
    final h = _Harness(
      stored: null,
      defaultMode: AuthMode.optional,
      route: (_) => json(200, {}),
    );
    final res = await h.dio.get<dynamic>('/public');
    expect(res.statusCode, 200);
  });

  test('a 401 refreshes once, stores the tokens and retries', () async {
    final h = _Harness();
    final res = await h.dio.get<dynamic>('/me');

    expect(res.statusCode, 200);
    expect(res.data, {'ok': true});
    expect(h.refreshCalls, 1);
    expect(h.sentAuth, ['Bearer a1', 'Bearer a2']);
    expect(await h.storage.read(), _fresh);
    expect(h.events.single, isA<TokenRefreshed>());
  });

  test('a revoked token that has not expired is still refreshed', () async {
    final unexpired = TokenPair(
      accessToken: fakeJwt(
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
      refreshToken: 'r1',
    );
    final h = _Harness(stored: unexpired);
    final res = await h.dio.get<dynamic>('/me');

    expect(res.statusCode, 200);
    expect(h.refreshCalls, 1);
  });

  test('concurrent 401s share a single refresh', () async {
    final h = _Harness();
    final results = await Future.wait(
      List.generate(5, (i) => h.dio.get<dynamic>('/item/$i')),
    );

    expect(results.map((r) => r.statusCode), everyElement(200));
    expect(h.refreshCalls, 1);
    expect(h.sentAuth.where((a) => a == 'Bearer a2'), hasLength(5));
  });

  test('a 401 on the retried request does not loop', () async {
    final h = _Harness(route: (_) => json(401, {}));

    await expectLater(
      h.dio.get<dynamic>('/me'),
      throwsA(
        isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401),
      ),
    );
    expect(h.refreshCalls, 1);
    expect(h.server.requests, hasLength(2));
  });

  test('SkipRefresh passes the 401 straight through', () async {
    final h = _Harness();

    await expectLater(
      h.dio.post<dynamic>(
        '/auth/logout',
        options: AuthExtra.options(skipRefresh: true),
      ),
      throwsA(isA<DioException>()),
    );
    expect(h.refreshCalls, 0);
    expect(h.sentAuth, ['Bearer a1']);
  });

  test('a rejected refresh ends the session once for all waiters', () async {
    var calls = 0;
    final h = _Harness(
      refresh: (_, __) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw httpError(401);
      },
    );

    final outcomes = await Future.wait(
      List.generate(
        3,
        (i) => h.dio
            .get<dynamic>('/item/$i')
            .then<Object>((r) => r, onError: (Object e) => e),
      ),
    );

    for (final outcome in outcomes) {
      expect(
        outcome,
        isA<DioException>()
            .having((e) => e.requestOptions.path, 'path', startsWith('/item/'))
            .having((e) => e.response?.statusCode, 'status', 401),
      );
    }
    expect(calls, 1);
    expect(h.sessionExpired, 1);
    expect(await h.storage.read(), isNull);
    expect(h.events, [isA<RefreshFailed>(), isA<SessionExpired>()]);
  });

  test('a transient refresh failure keeps the session', () async {
    final h = _Harness(
      refresh: (_, __) async => throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/auth/refresh'),
        reason: 'offline',
      ),
    );

    await expectLater(h.dio.get<dynamic>('/me'), throwsA(isA<DioException>()));
    expect(h.sessionExpired, 0);
    expect(await h.storage.read(), _stale);
    expect(h.events.single, isA<RefreshFailed>());
  });

  test('a 401 without a refresh token ends the session', () async {
    final h = _Harness(stored: const TokenPair(accessToken: 'a1'));

    await expectLater(h.dio.get<dynamic>('/me'), throwsA(isA<DioException>()));
    expect(h.refreshCalls, 0);
    expect(h.sessionExpired, 1);
    expect(await h.storage.read(), isNull);
  });

  test('isSessionInvalid ends the session without refreshing', () async {
    final h = _Harness(
      route: (_) => json(403, {'code': 'user_blocked'}),
      isSessionInvalid: (e) =>
          (e.response?.data as Map?)?['code'] == 'user_blocked',
    );

    await expectLater(h.dio.get<dynamic>('/me'), throwsA(isA<DioException>()));
    expect(h.refreshCalls, 0);
    expect(h.sessionExpired, 1);
    expect(await h.storage.read(), isNull);
  });

  test('a token refreshed elsewhere is reused without refreshing', () async {
    late _Harness h;
    h = _Harness(
      route: (options) async {
        if (options.headers['Authorization'] == 'Bearer a1') {
          // Another request refreshed while this one was on the wire.
          await h.storage.write(_fresh);
          return json(401, {});
        }
        return json(200, {'ok': true});
      },
    );

    final res = await h.dio.get<dynamic>('/me');
    expect(res.statusCode, 200);
    expect(h.refreshCalls, 0);
    expect(h.sentAuth, ['Bearer a1', 'Bearer a2']);
  });

  test('refreshes before sending when the JWT is about to expire', () async {
    final h = _Harness(
      stored: TokenPair(
        accessToken: fakeJwt(
          expiresAt: DateTime.now().add(const Duration(seconds: 5)),
        ),
        refreshToken: 'r1',
      ),
    );

    final res = await h.dio.get<dynamic>('/me');
    expect(res.statusCode, 200);
    expect(h.refreshCalls, 1);
    expect(h.sentAuth, ['Bearer a2']);
  });

  test('no proactive refresh without a refresh token or leeway', () async {
    final expiring = fakeJwt(
      expiresAt: DateTime.now().add(const Duration(seconds: 5)),
    );
    final noRefreshToken = _Harness(
      stored: TokenPair(accessToken: expiring),
      route: (_) => json(200, {}),
    );
    await noRefreshToken.dio.get<dynamic>('/me');
    expect(noRefreshToken.refreshCalls, 0);

    final disabled = _Harness(
      stored: TokenPair(accessToken: expiring, refreshToken: 'r1'),
      route: (_) => json(200, {}),
      proactiveLeeway: null,
    );
    await disabled.dio.get<dynamic>('/me');
    expect(disabled.refreshCalls, 0);
  });

  test('keeps the refresh token when the server does not rotate it', () async {
    final h = _Harness(
      refresh: (_, __) async => const TokenPair(accessToken: 'a2'),
    );
    await h.dio.get<dynamic>('/me');

    expect(
      await h.storage.read(),
      const TokenPair(accessToken: 'a2', refreshToken: 'r1'),
    );
  });

  test('retries a FormData body with a fresh copy', () async {
    final h = _Harness();
    final form = FormData.fromMap({'name': 'photo'});
    final res = await h.dio.post<dynamic>('/upload', data: form);

    expect(res.statusCode, 200);
    expect(h.server.requests, hasLength(2));
    expect(h.server.requests[1].data, isA<FormData>());
    expect(identical(h.server.requests[1].data, form), isFalse);
  });

  test('refreshDio shares the adapter but not the interceptors', () async {
    final h = _Harness(
      route: (options) {
        if (options.path == '/auth/refresh') {
          return json(200, {'access_token': 'a2'});
        }
        return FakeServer.acceptTokens({'a2'})(options);
      },
      refresh: (refreshDio, current) async {
        final res = await refreshDio.post<Map<String, dynamic>>(
          '/auth/refresh',
          data: {'refresh_token': current.refreshToken},
        );
        return TokenPair(accessToken: res.data!['access_token'] as String);
      },
    );

    final res = await h.dio.get<dynamic>('/me');
    expect(res.statusCode, 200);

    final refreshRequest =
        h.server.requests.singleWhere((r) => r.path == '/auth/refresh');
    expect(refreshRequest.uri.toString(), 'https://api.test/auth/refresh');
    expect(refreshRequest.headers['Authorization'], isNull);
    expect(h.interceptor.refreshDio.interceptors.whereType<AuthInterceptor>(),
        isEmpty);
  });
}
