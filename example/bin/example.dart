import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:dio_auth_kit_example/api_client.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  final storage = InMemoryTokenStorage();

  final auth = AuthInterceptor(
    dio: dio,
    storage: storage,
    refresh: (refreshDio, current) async {
      final res = await refreshDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': current.refreshToken},
      );
      return TokenPair(
        accessToken: res.data!['access_token'] as String,
        refreshToken: res.data!['refresh_token'] as String?,
      );
    },
    onSessionExpired: () => print('Session expired: show the login screen'),
  );
  dio.interceptors.add(auth);
  auth.events.listen((event) => print('auth event: $event'));

  final api = ApiClient(dio);

  final login = await api.login({'username': 'demo', 'password': 'demo'});
  await storage.write(
    TokenPair(
      accessToken: login['access_token'] as String,
      refreshToken: login['refresh_token'] as String?,
    ),
  );

  print(await api.me());
}
