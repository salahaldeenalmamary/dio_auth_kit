import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Records requests; answers 401 for logout and 200 otherwise.
class FakeServer implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) await requestStream.drain<void>();
    final status = options.path == '/auth/logout' ? 401 : 200;
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
