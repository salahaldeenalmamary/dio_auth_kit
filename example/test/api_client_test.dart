import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:dio_auth_kit_example/api_client.dart';
import 'package:test/test.dart';

import 'support/server.dart';

void main() {
  late FakeServer server;
  late ApiClient api;
  var refreshCalls = 0;

  setUp(() {
    server = FakeServer();
    refreshCalls = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = server;
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        storage: InMemoryTokenStorage(
          const TokenPair(accessToken: 'a1', refreshToken: 'r1'),
        ),
        refresh: (_, __) async {
          refreshCalls++;
          return const TokenPair(accessToken: 'a2');
        },
      ),
    );
    api = ApiClient(dio);
  });

  test('the generated client carries @NoAuth into extra', () async {
    await api.login({'username': 'demo'});
    final request = server.requests.single;

    expect(request.extra[AuthExtra.mode], 'none');
    expect(request.headers['Authorization'], isNull);
  });

  test('an unannotated method uses the default mode', () async {
    await api.me();
    final request = server.requests.single;

    expect(request.extra.containsKey(AuthExtra.mode), isFalse);
    expect(request.headers['Authorization'], 'Bearer a1');
  });

  test('the generated client carries @OptionalAuth into extra', () async {
    await api.catalog();
    expect(server.requests.single.extra[AuthExtra.mode], 'optional');
  });

  test('the generated client carries @SkipRefresh into extra', () async {
    await expectLater(api.logout(), throwsA(isA<DioException>()));
    final request = server.requests.single;

    expect(request.extra[AuthExtra.skipRefresh], isTrue);
    expect(request.headers['Authorization'], 'Bearer a1');
    expect(refreshCalls, 0);
  });
}
