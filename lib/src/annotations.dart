import 'package:retrofit/retrofit.dart';

import 'auth_extra.dart';

// Method-level settings; they win over `AuthScope` and the interceptor's
// defaults. These subclass retrofit's `Extra`, so retrofit_generator merges
// their maps into the generated request's `extra` with no extra generator.
// Map values stay string literals: `AuthMode.x.name` is not a constant.

/// Attach the token, refresh on 401 and fail fast without a session.
///
/// Only needed when the client scope or the interceptor's `defaultMode` is
/// something other than [AuthMode.required].
class Authenticated extends Extra {
  const Authenticated() : super(const {AuthExtra.mode: 'required'});
}

/// Attach the token when one exists; never refresh or fail for it.
class OptionalAuth extends Extra {
  const OptionalAuth() : super(const {AuthExtra.mode: 'optional'});
}

/// Never attach a token, such as for login or registration endpoints.
///
/// ```dart
/// @NoAuth()
/// @POST('/auth/login')
/// Future<TokenRes> login(@Body() LoginReq body);
/// ```
class NoAuth extends Extra {
  const NoAuth() : super(const {AuthExtra.mode: 'none'});
}

/// Attach the token but pass a 401 straight through without refreshing,
/// such as for logout.
class SkipRefresh extends Extra {
  const SkipRefresh() : super(const {AuthExtra.skipRefresh: true});
}

/// Refresh on 401 even when the client scope or the interceptor default
/// skips refreshing.
class AllowRefresh extends Extra {
  const AllowRefresh() : super(const {AuthExtra.skipRefresh: false});
}
