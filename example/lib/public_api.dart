import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:retrofit/retrofit.dart';

part 'public_api.g.dart';

/// Every method is public unless it says otherwise, and a 403 on an
/// authenticated method ends the session.
@RestApi(headers: {...AuthScope.none, AuthScope.expireOnHeader: '403'})
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
