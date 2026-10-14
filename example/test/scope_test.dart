import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:dio_auth_kit_example/api_client.dart';
import 'package:dio_auth_kit_example/public_api.dart';
import 'package:test/test.dart';

import 'support/server.dart';

void main() {
  late FakeServer server;
  late Dio dio;
  late InMemoryTokenStorage storage;
  var refreshCalls = 0;

  setUp(() {
    refreshCalls = 0;
    storage = InMemoryTokenStorage(
      const TokenPair(accessToken: 'a1', refreshToken: 'r1'),
    );
    server = FakeServer({'/orders': 419, '/password': 401, '/news/saved': 403});
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = server;
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        storage: storage,
        refresh: (_, __) async {
          refreshCalls++;
          return const TokenPair(accessToken: 'a2');
        },
      ),
    );
  });

  test('@RestApi(headers: AuthScope.none) makes every method public', () async {
    await PublicApi(dio).news();
    final request = server.requests.single;

    expect(request.headers['Authorization'], isNull);
    expect(request.headers.containsKey(AuthScope.modeHeader), isFalse);
  });

  test('a method annotation beats the @RestApi scope', () async {
    await expectLater(PublicApi(dio).savedNews(), throwsA(isA<DioException>()));
    final request = server.requests.single;

    expect(request.headers['Authorization'], 'Bearer a1');
    expect(request.headers.keys.where(AuthScope.isMarker), isEmpty);
  });

  test('the @RestApi expireOn header ends the session on 403', () async {
    await expectLater(PublicApi(dio).savedNews(), throwsA(isA<DioException>()));

    expect(refreshCalls, 0);
    expect(await storage.read(), isNull);
  });

  test('@RefreshOn([401, 419]) reaches the generated extra', () async {
    final res = await ApiClient(dio).orders();

    expect(res, {'ok': true});
    expect(refreshCalls, 1);
    expect(server.requests.first.extra[AuthExtra.refreshOn], [401, 419]);
  });

  test('@PassThroughOn([401]) leaves the session alone', () async {
    await expectLater(
      ApiClient(dio).changePassword({'current': 'wrong'}),
      throwsA(isA<DioException>()),
    );

    expect(refreshCalls, 0);
    expect(server.requests.single.extra[AuthExtra.passThroughOn], [401]);
    expect(await storage.read(), isNotNull);
  });

  test('AuthScope.dio scopes a client on any retrofit version', () async {
    final api = ApiClient(AuthScope.dio(dio, mode: AuthMode.none));
    await api.me();

    expect(server.requests.single.headers['Authorization'], isNull);
  });
}
