import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

const _stale = TokenPair(accessToken: 'a1', refreshToken: 'r1');

class _Setup {
  _Setup({
    AuthMode defaultMode = AuthMode.required,
    bool defaultSkipRefresh = false,
    Route? route,
  }) {
    server = FakeServer(route ?? FakeServer.acceptTokens({'a2'}));
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = server;
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        storage: storage,
        defaultMode: defaultMode,
        defaultSkipRefresh: defaultSkipRefresh,
        refresh: (_, __) async {
          refreshCalls++;
          return const TokenPair(accessToken: 'a2', refreshToken: 'r2');
        },
      ),
    );
  }

  final storage = InMemoryTokenStorage(_stale);
  late final FakeServer server;
  late final Dio dio;
  var refreshCalls = 0;

  RequestOptions get last => server.requests.last;

  Future<Response<dynamic>> get(
    String path, {
    Map<String, String> scope = const {},
    Map<String, Object> extra = const {},
  }) =>
      dio.get<dynamic>(path, options: Options(headers: scope, extra: extra));
}

Matcher _noMarkers() => predicate<RequestOptions>(
      (r) => r.headers.keys.every(
        (k) =>
            k.toLowerCase() != AuthScope.modeHeader &&
            k.toLowerCase() != AuthScope.skipRefreshHeader,
      ),
      'has no AuthScope marker headers',
    );

void main() {
  test('a client scope of none sends no token and strips the marker', () async {
    final s = _Setup(route: (_) => json(200, {}));
    await s.get('/public', scope: AuthScope.none);

    expect(s.last.headers['Authorization'], isNull);
    expect(s.last, _noMarkers());
  });

  test('markers are stripped whatever their casing', () async {
    final s = _Setup(route: (_) => json(200, {}));
    await s.get('/public', scope: {'X-Dio-Auth-Kit-Mode': 'none'});

    expect(s.last.headers['Authorization'], isNull);
    expect(s.last, _noMarkers());
  });

  test('a method setting beats the client scope', () async {
    final s = _Setup(route: (_) => json(200, {}));
    await s.get(
      '/me',
      scope: AuthScope.none,
      extra: AuthExtra.extras(mode: AuthMode.required),
    );

    expect(s.last.headers['Authorization'], 'Bearer a1');
  });

  test('the client scope beats the global default', () async {
    final s = _Setup();
    await s.storage.clear();
    s.server.route = (_) => json(200, {});

    // Global required would fail fast without a session; optional does not.
    final res = await s.get('/catalog', scope: AuthScope.optional);
    expect(res.statusCode, 200);
    expect(s.last.headers['Authorization'], isNull);
  });

  test('the global default applies when nothing else is set', () async {
    final s = _Setup(defaultMode: AuthMode.none, route: (_) => json(200, {}));
    await s.get('/anything');

    expect(s.last.headers['Authorization'], isNull);
  });

  test('a client skipRefresh passes 401s through', () async {
    final s = _Setup();
    await expectLater(
      s.get('/me', scope: AuthScope.skipRefresh),
      throwsA(isA<DioException>()),
    );
    expect(s.refreshCalls, 0);
  });

  test('AllowRefresh on the method beats a client skipRefresh', () async {
    final s = _Setup();
    final res = await s.get(
      '/me',
      scope: AuthScope.skipRefresh,
      extra: AuthExtra.extras(skipRefresh: false),
    );

    expect(res.statusCode, 200);
    expect(s.refreshCalls, 1);
  });

  test('defaultSkipRefresh applies globally and can be overridden', () async {
    final s = _Setup(defaultSkipRefresh: true);
    await expectLater(s.get('/me'), throwsA(isA<DioException>()));
    expect(s.refreshCalls, 0);

    final allowed = await s.get('/me', scope: AuthScope.allowRefresh);
    expect(allowed.statusCode, 200);
    expect(s.refreshCalls, 1);
  });

  test('a retry keeps the client scope and stays free of markers', () async {
    final s = _Setup();
    final res = await s.get(
      '/me',
      scope: {...AuthScope.required, ...AuthScope.allowRefresh},
    );

    expect(res.statusCode, 200);
    expect(s.server.requests, hasLength(2));
    expect(s.server.requests, everyElement(_noMarkers()));
    expect(s.last.extra[AuthExtra.scopeMode], 'required');
    expect(s.last.extra[AuthExtra.scopeSkipRefresh], isFalse);
  });

  test('an unknown marker value falls back to the next scope', () async {
    final s = _Setup(route: (_) => json(200, {}));
    await s.get('/me', scope: {AuthScope.modeHeader: 'bogus'});

    expect(s.last.headers['Authorization'], 'Bearer a1');
    expect(s.last, _noMarkers());
  });

  group('AuthScope.dio', () {
    test('applies the scope through the shared interceptors', () async {
      final s = _Setup(route: (_) => json(200, {}));
      final public = AuthScope.dio(s.dio, mode: AuthMode.none);

      await public.get<dynamic>('/public');
      expect(s.last.headers['Authorization'], isNull);
      expect(s.last, _noMarkers());

      await s.dio.get<dynamic>('/me');
      expect(s.last.headers['Authorization'], 'Bearer a1');
    });

    test('shares the adapter and leaves the base options untouched', () {
      final s = _Setup();
      final scoped = AuthScope.dio(s.dio, mode: AuthMode.optional);

      expect(
          identical(scoped.httpClientAdapter, s.dio.httpClientAdapter), isTrue);
      expect(scoped.interceptors, orderedEquals(s.dio.interceptors));
      expect(scoped.options.baseUrl, s.dio.options.baseUrl);
      expect(s.dio.options.headers[AuthScope.modeHeader], isNull);
    });

    test('refreshes and retries through the base client', () async {
      final s = _Setup();
      final scoped = AuthScope.dio(s.dio, mode: AuthMode.required);

      final res = await scoped.get<dynamic>('/me');
      expect(res.statusCode, 200);
      expect(s.refreshCalls, 1);
      expect(s.server.requests, everyElement(_noMarkers()));
    });
  });

  group('status rules', () {
    test('a method passThroughOn beats the global refresh', () async {
      final s = _Setup();
      await expectLater(
        s.get('/password', extra: AuthExtra.extras(passThroughOn: {401})),
        throwsA(isA<DioException>()),
      );
      expect(s.refreshCalls, 0);
      expect(await s.storage.read(), _stale);
    });

    test('a client refreshOn header applies and is stripped', () async {
      final s = _Setup(
        route: (options) => options.headers['Authorization'] == 'Bearer a2'
            ? json(200, {})
            : json(419, {}),
      );
      final res = await s.get(
        '/me',
        scope: {AuthScope.refreshOnHeader: '401, 419'},
      );

      expect(res.statusCode, 200);
      expect(s.refreshCalls, 1);
      expect(s.server.requests, everyElement(_noMarkers()));
    });

    test('a method set beats a client set', () async {
      final s = _Setup();
      final res = await s.get(
        '/me',
        scope: {AuthScope.expireOnHeader: '401'},
        extra: AuthExtra.extras(refreshOn: {401}),
      );

      expect(res.statusCode, 200);
      expect(s.refreshCalls, 1);
    });

    test('pass-through wins over expire within one level', () async {
      final s = _Setup();
      await expectLater(
        s.get(
          '/me',
          extra: AuthExtra.extras(expireOn: {401}, passThroughOn: {401}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(await s.storage.read(), _stale);
    });

    test('AuthScope.dio carries status rules', () async {
      final s = _Setup(route: (_) => json(403, {}));
      final scoped = AuthScope.dio(s.dio, expireOn: {403});

      await expectLater(
        scoped.get<dynamic>('/me'),
        throwsA(isA<DioException>()),
      );
      expect(await s.storage.read(), isNull);
      expect(s.server.requests, everyElement(_noMarkers()));
    });
  });
}
