import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Records requests. Paths in [failures] answer that status unless the
/// request carries the refreshed token `a2`; everything else answers 200.
class FakeServer implements HttpClientAdapter {
  FakeServer([this.failures = const {'/auth/logout': 401}]);

  final Map<String, int> failures;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) await requestStream.drain<void>();
    final failure = failures[options.path];
    final refreshed = options.headers['Authorization'] == 'Bearer a2';
    final status = failure != null && !refreshed ? failure : 200;
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
