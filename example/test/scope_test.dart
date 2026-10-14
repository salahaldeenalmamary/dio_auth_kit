import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:dio_auth_kit_example/api_client.dart';
import 'package:dio_auth_kit_example/public_api.dart';
import 'package:test/test.dart';

import 'support/server.dart';

void main() {
  late FakeServer server;
  late Dio dio;

  setUp(() {
    server = FakeServer();
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = server;
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        storage: InMemoryTokenStorage(const TokenPair(accessToken: 'a1')),
        refresh: (_, __) async => const TokenPair(accessToken: 'a2'),
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
    await PublicApi(dio).savedNews();
    final request = server.requests.single;

    expect(request.headers['Authorization'], 'Bearer a1');
    expect(request.headers.containsKey(AuthScope.modeHeader), isFalse);
  });

  test('AuthScope.dio scopes a client on any retrofit version', () async {
    final api = ApiClient(AuthScope.dio(dio, mode: AuthMode.none));
    await api.me();

    expect(server.requests.single.headers['Authorization'], isNull);
  });
}
