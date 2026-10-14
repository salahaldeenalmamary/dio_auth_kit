/// Carried in `DioException.error` when an `AuthMode.required` request is
/// made without a session. The request never reaches the network.
///
/// ```dart
/// on DioException catch (e) {
///   if (e.error is NoSessionError) showLogin();
/// }
/// ```
class NoSessionError implements Exception {
  const NoSessionError();

  @override
  String toString() => 'NoSessionError: no auth session for this request';
}
