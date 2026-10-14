import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:test/test.dart';

DioException _error(
  int status, {
  Object? data,
  Map<String, List<String>> headers = const {},
}) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: data,
      headers: Headers.fromMap(headers),
    ),
  );
}

void main() {
  group('AuthErrorRule', () {
    test('matches statuses', () {
      const rule = AuthErrorRule.refreshOn({401, 419});
      expect(rule.matches(_error(419)), isTrue);
      expect(rule.matches(_error(403)), isFalse);
      expect(const AuthErrorRule(AuthErrorAction.refresh).matches(_error(500)),
          isTrue);
    });

    test('never matches an error without a response', () {
      final offline = DioException.connectionError(
        requestOptions: RequestOptions(path: '/x'),
        reason: 'offline',
      );
      expect(const AuthErrorRule(AuthErrorAction.refresh).matches(offline),
          isFalse);
    });

    test('bodyFields compares nested values by dot path', () {
      const rule = AuthErrorRule.expireOn(
        {403},
        bodyFields: {'error.code': 'BLOCKED', 'error.retry': null},
      );
      expect(
        rule.matches(_error(403, data: {
          'error': {'code': 'BLOCKED', 'retry': null},
        })),
        isTrue,
      );
      expect(
        rule.matches(_error(403, data: {
          'error': {'code': 'BLOCKED'},
        })),
        isFalse,
        reason: 'a missing key is not a null value',
      );
      expect(
        rule.matches(
            _error(403, data: '{"error":{"code":"BLOCKED","retry":null}}')),
        isTrue,
        reason: 'JSON text bodies are decoded',
      );
      expect(rule.matches(_error(403, data: 'not json')), isFalse);
    });

    test('bodyContains reads text, JSON and byte bodies', () {
      const rule =
          AuthErrorRule.expireOn({404}, bodyContains: 'USER NOT FOUND');
      expect(rule.matches(_error(404, data: 'user not found')), isTrue);
      expect(rule.matches(_error(404, data: {'detail': 'User not found'})),
          isTrue);
      expect(
        rule.matches(_error(404, data: utf8.encode('User not found'))),
        isTrue,
      );
      expect(rule.matches(_error(404, data: {'detail': 'gone'})), isFalse);
    });

    test('a RegExp body pattern is applied as given', () {
      final rule = AuthErrorRule.expireOn(
        {401},
        bodyContains: RegExp(r'"code":"E\d+"'),
      );
      expect(rule.matches(_error(401, data: {'code': 'E42'})), isTrue);
      expect(rule.matches(_error(401, data: {'code': 'X42'})), isFalse);
    });

    test('headerContains matches header names case-insensitively', () {
      const rule = AuthErrorRule.refreshOn(
        {401},
        headerContains: {'WWW-Authenticate': 'invalid_token'},
      );
      expect(
        rule.matches(_error(401, headers: {
          'www-authenticate': ['Bearer error="invalid_token"'],
        })),
        isTrue,
      );
      expect(rule.matches(_error(401)), isFalse);
    });

    test('every condition must hold', () {
      final rule = AuthErrorRule.expireOn(
        {403},
        bodyContains: 'blocked',
        when: (e) => e.requestOptions.path == '/x',
      );
      expect(rule.matches(_error(403, data: 'blocked')), isTrue);
      expect(rule.matches(_error(403, data: 'fine')), isFalse);
      expect(rule.matches(_error(401, data: 'blocked')), isFalse);
    });
  });

  group('AuthErrorPolicy', () {
    test('defaults to refreshing on 401', () {
      const policy = AuthErrorPolicy();
      expect(policy.actionFor(_error(401)), AuthErrorAction.refresh);
      expect(policy.actionFor(_error(403)), isNull);
    });

    test('the first matching rule wins', () {
      const policy = AuthErrorPolicy(
        rules: [
          AuthErrorRule.expireOn({401}, bodyContains: 'user not found'),
          AuthErrorRule.refreshOn({401}),
        ],
      );
      expect(
        policy.actionFor(_error(401, data: 'User not found')),
        AuthErrorAction.expireSession,
      );
      expect(policy.actionFor(_error(401)), AuthErrorAction.refresh);
    });

    test('endsSession defaults', () {
      const policy = AuthErrorPolicy();
      expect(policy.endsSession(_error(401)), isTrue);
      expect(policy.endsSession(_error(400)), isTrue);
      expect(policy.endsSession(_error(503)), isFalse);
      expect(
        policy.endsSession(DioException.connectionTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: RequestOptions(path: '/x'),
        )),
        isFalse,
      );
      expect(policy.endsSession(const FormatException('bad body')), isTrue);
    });
  });

  group('AuthExtra.statusesOf', () {
    test('reads lists, sets and comma strings', () {
      expect(AuthExtra.statusesOf([401, 419]), {401, 419});
      expect(AuthExtra.statusesOf({403}), {403});
      expect(AuthExtra.statusesOf(' 401, 419 ,x'), {401, 419});
      expect(AuthExtra.statusesOf(null), isEmpty);
    });
  });
}
