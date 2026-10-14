import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:retrofit/retrofit.dart';

part 'api_client.g.dart';

@RestApi()
abstract class ApiClient {
  factory ApiClient(Dio dio, {String? baseUrl}) = _ApiClient;

  /// Public: never sends a token.
  @NoAuth()
  @POST('/auth/login')
  Future<dynamic> login(@Body() Map<String, dynamic> body);

  /// No annotation: uses the interceptor's `defaultMode` (required).
  @GET('/me')
  Future<dynamic> me();

  /// Sends the token when signed in, works signed out too.
  @OptionalAuth()
  @GET('/catalog')
  Future<dynamic> catalog();

  /// Sends the token; a 401 here must not trigger a refresh.
  @SkipRefresh()
  @POST('/auth/logout')
  Future<void> logout();
}
