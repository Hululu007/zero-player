/// Called immediately before each source request and each GET redirect.
/// [reference] preserves a Legado POST body when one is present.
typedef BookRequestGuard = void Function(Uri target, String? reference);
