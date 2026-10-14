## 0.1.0

- `AuthInterceptor`: bearer header injection, single-flight token refresh,
  retry of the failed request, proactive refresh before JWT expiry.
- Retrofit-compatible annotations: `@Authenticated`, `@OptionalAuth`,
  `@NoAuth`, `@SkipRefresh`.
- `TokenStorage` interface with `InMemoryTokenStorage` and `CachedTokenStorage`.
- `AuthEvent` stream: `TokenRefreshed`, `RefreshFailed`, `SessionExpired`.
