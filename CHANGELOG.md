## 0.1.0

- `AuthInterceptor`: bearer header injection, single-flight token refresh,
  retry of the failed request, proactive refresh before JWT expiry.
- Retrofit-compatible annotations: `@Authenticated`, `@OptionalAuth`,
  `@NoAuth`, `@SkipRefresh`, `@AllowRefresh`.
- Scopes: settings resolve from the method, then the client, then the
  interceptor.
- Client scope: `@RestApi(headers: AuthScope.none)` (retrofit >= 4.8) or
  `AuthScope.dio(dio, mode: ...)` on any retrofit version. The marker headers
  are removed before the request is sent.
- Global scope: `AuthInterceptor(defaultMode:, defaultSkipRefresh:)`.
- Error rules decide refresh, end of session or pass-through from the
  backend's error: `@RefreshOn`, `@ExpireOn` and `@PassThroughOn` per method,
  `AuthScope` status headers per client, and `AuthErrorPolicy` globally, which
  matches on status, JSON body fields, body text, response headers or any
  predicate.
- `TokenStorage` interface with `InMemoryTokenStorage` and `CachedTokenStorage`.
- `AuthEvent` stream: `TokenRefreshed`, `RefreshFailed`, `SessionExpired`.
