import 'dart:convert';

import 'package:dio_auth_kit/dio_auth_kit.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  test('reads exp from an unpadded payload', () {
    final exp = DateTime.utc(2030, 1, 2, 3, 4, 5);
    expect(Jwt.tryExpiry(fakeJwt(expiresAt: exp)), exp);
  });

  test('reads exp from a padded payload', () {
    final payload = base64Url.encode(utf8.encode('{"exp":10}'));
    expect(payload, endsWith('='));
    expect(
      Jwt.tryExpiry('h.$payload.s'),
      DateTime.fromMillisecondsSinceEpoch(10000, isUtc: true),
    );
  });

  test('returns null for malformed tokens', () {
    for (final token in ['', 'opaque-token', 'a.b', 'a.!!!.c', 'a..c']) {
      expect(Jwt.tryDecodePayload(token), isNull, reason: token);
    }
    final notAnObject = base64Url.encode(utf8.encode('[1]'));
    expect(Jwt.tryDecodePayload('h.$notAnObject.s'), isNull);
  });

  test('returns null when exp is missing or not a number', () {
    String token(String payload) =>
        'h.${base64Url.encode(utf8.encode(payload))}.s';
    expect(Jwt.tryExpiry(token('{"sub":"1"}')), isNull);
    expect(Jwt.tryExpiry(token('{"exp":"soon"}')), isNull);
  });

  test('TokenPair uses expiresAt before the JWT claim', () {
    final pair = TokenPair(
      accessToken: fakeJwt(expiresAt: DateTime.utc(2030)),
      expiresAt: DateTime.utc(2001),
    );
    expect(pair.isExpired(now: DateTime.utc(2002)), isTrue);
    expect(const TokenPair(accessToken: 'opaque').isExpired(), isFalse);
  });

  test('TokenPair.toString masks tokens', () {
    final text =
        const TokenPair(accessToken: 'secret', refreshToken: 'r').toString();
    expect(text, isNot(contains('secret')));
  });
}
