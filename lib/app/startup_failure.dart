/// Cleanup could not confirm that every resource stopped. A new startup in
/// this process must not contend with resources retained by the failed attempt.
final class ApplicationRestartRequired implements Exception {
  const ApplicationRestartRequired({this.startupError, this.cleanupError});
  final Object? startupError;
  final Object? cleanupError;
}
