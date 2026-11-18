import 'segment_store.dart';

abstract interface class SegmentMetadata {
  Future<Map<String, StoredResource>> entries();
  Future<void> put(String key, StoredResource value);
  Future<void> remove(String key);
  Future<Set<String>> protectedKeys();
  Future<Set<String>> ownedKeys(String owner);
  Future<Map<String, Set<String>>> ownedKeysFor(Set<String> owners);
  Future<void> pin(String owner, String key);
  Future<void> unpin(String owner);
  Future<void> retainPins(String owner, Set<String> keys);
}

/// Recovery may retain damaged indexed payloads without exposing their headers.
abstract interface class SegmentRecoveryMetadata {
  Future<Set<String>> indexedKeys();
}
