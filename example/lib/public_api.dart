import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:retrofit/retrofit.dart';

part 'public_api.g.dart';

/// Every method is public unless it says otherwise.
@RestApi(headers: AuthScope.none)
abstract class PublicApi {
  factory PublicApi(Dio dio, {String? baseUrl}) = _PublicApi;

  /// Inherits the client scope: no token.
  @GET('/news')
  Future<dynamic> news();

  /// The method setting beats the client scope.
  @Authenticated()
  @GET('/news/saved')
  Future<dynamic> savedNews();
}
