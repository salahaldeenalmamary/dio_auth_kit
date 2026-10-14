import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

typedef Route = FutureOr<ResponseBody> Function(RequestOptions options);

/// An in-process adapter: records every request and answers from [route].
class FakeServer implements HttpClientAdapter {
  FakeServer(this.route);

  Route route;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) await requestStream.drain<void>();
    return route(options);
  }

  @override
  void close({bool force = false}) {}

  /// Accepts only `Bearer <token>` where token is in [valid]; 401 otherwise.
  static Route acceptTokens(Set<String> valid) => (options) {
        final header = options.headers['Authorization'];
        final ok = header is String &&
            header.startsWith('Bearer ') &&
            valid.contains(header.substring(7));
        return ok
            ? json(200, {'ok': true})
            : json(401, {'error': 'unauthorized'});
      };
}

ResponseBody json(int status, Object? body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

String fakeJwt({required DateTime expiresAt}) {
  String part(Map<String, Object> map) =>
      base64Url.encode(utf8.encode(jsonEncode(map))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.'
      '${part({'exp': expiresAt.millisecondsSinceEpoch ~/ 1000})}.sig';
}

DioException httpError(int status, {String path = '/auth/refresh'}) {
  final options = RequestOptions(path: path);
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(requestOptions: options, statusCode: status),
    type: DioExceptionType.badResponse,
  );
}
