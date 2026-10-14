# dio_auth_kit

Bearer and JWT authentication for [dio](https://pub.dev/packages/dio) and
[retrofit](https://pub.dev/packages/retrofit):

- Attaches `Authorization: Bearer <token>` (or any header you build).
- Refreshes on 401 **once**, however many requests fail together, then
  retries them.
- Optionally refreshes **before** sending when the JWT `exp` is close.
- Sets auth per method (`@NoAuth`, `@OptionalAuth`, `@Authenticated`,
  `@SkipRefresh`, `@AllowRefresh`), per client (`@RestApi(headers:
  AuthScope.none)`) or for the whole dio. These work with the
  `retrofit_generator` you already use; there's no extra code generator.
- Ends the session cleanly: clears storage and calls `onSessionExpired` once.
  A network error during refresh doesn't sign the user out.

Pure Dart: no Flutter dependency.

## Install

```yaml
dependencies:
  dio_auth_kit:
    path: ../dio_auth_kit # or a git/pub reference
```

## Wire it up

```dart
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
final storage = CachedTokenStorage(SecureTokenStorage()); // see below

final auth = AuthInterceptor(
  dio: dio,
  storage: storage,
  refresh: (refreshDio, current) async {
    // refreshDio has dio's options and adapter but none of its interceptors.
    final res = await refreshDio.post<Map<String, dynamic>>(
      '/auth/refresh',
      data: {'refresh_token': current.refreshToken},
    );
    return TokenPair(
      accessToken: res.data!['access_token'] as String,
      refreshToken: res.data!['refresh_token'] as String?, // null keeps the old one
    );
  },
  onSessionExpired: () => router.go('/login'),
);
dio.interceptors.add(auth);
```

After login, store the tokens: `await storage.write(TokenPair(...))`. To log out,
call `await storage.clear()`.

## Annotate endpoints

```dart
@RestApi()
abstract class ApiClient {
  factory ApiClient(Dio dio, {String? baseUrl}) = _ApiClient;

  @NoAuth()
  @POST('/auth/login')
  Future<TokenRes> login(@Body() LoginReq body);

  @GET('/me') // no annotation → the interceptor's defaultMode
  Future<User> me();

  @OptionalAuth()
  @GET('/catalog')
  Future<List<Item>> catalog();

  @SkipRefresh()
  @POST('/auth/logout')
  Future<void> logout();
}
```

| Annotation | Sends token | Refreshes on 401 | Without a session |
| --- | --- | --- | --- |
| `@Authenticated()` | yes | yes | fails before the network with `NoSessionError` |
| `@OptionalAuth()` | if present | no | sent without a token |
| `@NoAuth()` | no | no | sent without a token |
| `@SkipRefresh()` | yes | no | combine with a mode |
| `@AllowRefresh()` | yes | yes | re-enables refresh skipped by a wider scope |

Plain dio calls use the same keys:

```dart
dio.post('/auth/login', options: AuthExtra.options(mode: AuthMode.none));
```

## Scopes

Every setting resolves from the most specific scope that sets it:

| Scope | Mode | Refresh on 401 |
| --- | --- | --- |
| 1. Method | `@NoAuth()`, `@OptionalAuth()`, `@Authenticated()` | `@SkipRefresh()`, `@AllowRefresh()` |
| 2. Client | `@RestApi(headers: AuthScope.none)`, or `AuthScope.dio(dio, mode: ...)` | `AuthScope.skipRefresh`, `AuthScope.allowRefresh` |
| 3. Global (the whole dio) | `AuthInterceptor(defaultMode: ...)` | `AuthInterceptor(defaultSkipRefresh: ...)` |

### Client scope with `@RestApi`

Needs retrofit >= 4.8 and retrofit_generator >= 10.1:

```dart
@RestApi(headers: AuthScope.none) // the whole client is public
abstract class PublicApi {
  factory PublicApi(Dio dio, {String? baseUrl}) = _PublicApi;

  @GET('/news')
  Future<List<News>> news(); // no token

  @Authenticated() // the method wins over the client
  @GET('/news/saved')
  Future<List<News>> savedNews();
}

// Combine settings by spreading the constants:
@RestApi(headers: {...AuthScope.optional, ...AuthScope.skipRefresh})
abstract class CatalogApi { ... }
```

retrofit only accepts class-level settings as headers. The constants are
marker headers (`x-dio-auth-kit-*`); `AuthInterceptor` reads them and removes
them before the request is sent, so they never reach your server.

### Client scope on older retrofit

Give the client a scoped Dio. It shares the adapter, transformer and
interceptors of the original Dio:

```dart
final publicApi = PublicApi(AuthScope.dio(dio, mode: AuthMode.none));
```

Create it after adding your interceptors; ones added to `dio` later aren't
copied.

### Global scope

```dart
AuthInterceptor(
  dio: dio,
  defaultMode: AuthMode.optional, // most of the API is public
  defaultSkipRefresh: false,
  ...
);
```

Set the global scope on the interceptor, not in `BaseOptions.extra`. dio
merges `BaseOptions.extra` into every request's method-level extras, so a
value set there would override the client scope.

## Secure storage on Flutter

The package doesn't ship a Flutter store. Implement `TokenStorage` over
`flutter_secure_storage`, and wrap it in `CachedTokenStorage` so each request
doesn't hit the keychain:

```dart
class SecureTokenStorage implements TokenStorage {
  static const _storage = FlutterSecureStorage();

  @override
  Future<TokenPair?> read() async {
    final access = await _storage.read(key: 'access_token');
    if (access == null) return null;
    return TokenPair(
      accessToken: access,
      refreshToken: await _storage.read(key: 'refresh_token'),
    );
  }

  @override
  Future<void> write(TokenPair tokens) async {
    await _storage.write(key: 'access_token', value: tokens.accessToken);
    await _storage.write(key: 'refresh_token', value: tokens.refreshToken);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
  }
}
```

## Options

| Parameter | Default | Purpose |
| --- | --- | --- |
| `headerBuilder` | `bearerHeader` | Build the auth headers from a `TokenPair`. |
| `shouldRefresh` | status 401 | Which errors trigger refresh and retry. |
| `isSessionRejection` | refresh 400/401/403 or a non-dio error | Which refresh errors end the session. Others, such as offline or 5xx, keep it. |
| `isSessionInvalid` | none | End the session without refreshing, such as a blocked or deleted user. |
| `proactiveLeeway` | 30 s | Refresh before sending when the token expires within this window. `null` disables it. |
| `defaultMode` | `required` | Mode when neither the method nor the client sets one. |
| `defaultSkipRefresh` | `false` | Skip refresh when neither the method nor the client says. |
| `refreshDio` | derived | Supply your own client for the refresh call. |

`auth.events` is a broadcast stream of `TokenRefreshed`, `RefreshFailed` and
`SessionExpired`.

## Migrating from a hand-written refresh interceptor

| Old | dio_auth_kit |
| --- | --- |
| `tokenStoreProvider` (sync) | `TokenStorage.read()` (async) |
| `onRefresh(dio, store)` | `refresh(refreshDio, current)` |
| `authHeader` | `headerBuilder` |
| `shouldRefresh(response)` | `shouldRefresh(DioException)` |
| `onFailed` | `onSessionExpired` + `events` |
| "user not found → logout" checks | `isSessionInvalid` |
| `retryInterceptors` | not needed: retries go through the same `dio` |

Behaviour that changes: a 401 now refreshes even when the local JWT hasn't
expired yet, which covers server-side revocation. A retried request never
refreshes a second time.

## Example

`example/` contains a retrofit client and tests that run the generated code:

```sh
cd example
dart pub get
dart run build_runner build -d
dart test
```
