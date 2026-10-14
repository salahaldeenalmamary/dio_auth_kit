import 'dart:async';

import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:test/test.dart';

void main() {
  test('concurrent callers share one refresh', () async {
    final coordinator = RefreshCoordinator();
    final gate = Completer<TokenPair>();
    var calls = 0;
    Future<TokenPair> refresh() {
      calls++;
      return gate.future;
    }

    final a = coordinator.run(refresh);
    final b = coordinator.run(refresh);
    expect(identical(a, b), isTrue);
    expect(coordinator.inFlight, isNotNull);

    gate.complete(const TokenPair(accessToken: 'new'));
    expect((await a).accessToken, 'new');
    expect((await b).accessToken, 'new');
    expect(calls, 1);
    expect(coordinator.inFlight, isNull);
  });

  test('a failure reaches every caller and allows a new attempt', () async {
    final coordinator = RefreshCoordinator();
    final gate = Completer<TokenPair>();

    final a = coordinator.run(() => gate.future);
    final b = coordinator.run(() => gate.future);
    gate.completeError(StateError('refresh failed'));

    await expectLater(a, throwsStateError);
    await expectLater(b, throwsStateError);
    expect(coordinator.inFlight, isNull);

    final retry = await coordinator.run(
      () async => const TokenPair(accessToken: 'second'),
    );
    expect(retry.accessToken, 'second');
  });

  test('a synchronous throw becomes a failed future', () async {
    final coordinator = RefreshCoordinator();
    await expectLater(
      coordinator.run(() => throw StateError('sync')),
      throwsStateError,
    );
    expect(coordinator.inFlight, isNull);
  });
}
