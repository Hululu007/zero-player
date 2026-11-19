import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/persistence/app_database.dart';
import 'book_vault_crypto.dart';

/// Raised when encrypted shelf data is touched without an unlocked vault.
final class VaultLockedException implements Exception {
  const VaultLockedException([this.message = '私密书架已锁定']);
  final String message;
  @override
  String toString() => message;
}

/// Password-derived, AES-GCM protected private bookshelf space.
///
/// Only the wrapped data key, a salt and the book-id index are stored in the
/// clear. Shelf records, notes, positions, offline text and provenance live
/// under `books_vault_data:` and are unreadable while locked.
final class BookVault extends ChangeNotifier {
  BookVault(this.db);

  final AppDatabase db;

  static const configKey = 'books_vault_config';
  static const indexKey = 'books_vault_index';
  static const guardKey = 'books_vault_guard';
  static const dataPrefix = 'books_vault_data:';
  static const _maxBooks = 5000;
  static const _maxFailures = 5;

  VaultConfig? _config;
  VaultCipher? _cipher;
  final Set<String> _ids = {};
  bool _loaded = false;
  int _failures = 0;
  int _lockUntil = 0;
  Timer? _autoLock;
  static const _idleLock = Duration(minutes: 30);

  bool get configured => _config != null;
  bool get unlocked => _cipher != null;
  String get hint => _config?.hint ?? '';
  bool get biometricEnabled => _config?.biometricEnabled ?? false;
  Set<String> get ids => Set.unmodifiable(_ids);
  int get lockedUntilMillis => _lockUntil;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final rows = await db.rows(
      'SELECT key,value FROM app_meta WHERE key IN (?,?,?)',
      [configKey, indexKey, guardKey],
    );
    for (final row in rows) {
      final value = _decode(row['value']);
      switch (row['key']) {
        case configKey:
          _config = VaultConfig.fromJson(value);
        case indexKey:
          _readIndex(value);
        case guardKey:
          if (value is Map) {
            _failures = _boundedInt(value['failures'], 0, 1000);
            _lockUntil = _boundedInt(value['lockUntil'], 0, 1 << 52);
          }
      }
    }
    _loaded = true;
  }

  Object? _decode(Object? raw) {
    if (raw is! String) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  int _boundedInt(Object? value, int min, int max) =>
      value is int && value >= min && value <= max ? value : min;

  void _readIndex(Object? value) {
    _ids.clear();
    if (value is! List) return;
    for (final id in value) {
      if (id is String && id.isNotEmpty && id.length <= 256) _ids.add(id);
      if (_ids.length >= _maxBooks) break;
    }
  }

  bool isPrivate(String bookId) => _ids.contains(bookId);

  Future<void> create(
    String password, {
    String hint = '',
    bool biometric = false,
  }) async {
    await ensureLoaded();
    if (_config != null) throw const FormatException('私密书架已存在');
    _validatePassword(password);
    final salt = newVaultSalt();
    final kek = await deriveVaultKey(password, base64Decode(salt));
    final dek = await randomVaultKey();
    var config = VaultConfig(
      salt: salt,
      wrappedKey: await wrapVaultKey(dek, kek),
      hint: hint.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final cipher = VaultCipher(dek);
    if (biometric && await VaultBiometric().available) {
      final wrapped = await VaultBiometric().wrap(dek);
      if (wrapped != null) config = config.withBiometric(wrapped);
    }
    await db.atomic(
      () async {
        await _put(configKey, jsonEncode(config.toJson()));
        await _put(indexKey, jsonEncode(const <String>[]));
        await db.write('DELETE FROM app_meta WHERE key=?', [guardKey]);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
    _config = config;
    _cipher = cipher;
    _ids.clear();
    _failures = 0;
    _lockUntil = 0;
    notifyListeners();
  }

  void _validatePassword(String password) {
    if (password.length < 6 || password.length > 128) {
      throw const FormatException('私密书架密码需为 6-128 个字符');
    }
  }

  /// Returns false for a wrong password without leaking why decryption failed.
  Future<bool> unlock(String password) async {
    await ensureLoaded();
    final config = _config;
    if (config == null) throw const FormatException('尚未设置私密书架');
    _checkLockout();
    final kek = await deriveVaultKey(password, base64Decode(config.salt));
    final dek = await unwrapVaultKey(config.wrappedKey, kek);
    if (dek == null) {
      await _recordFailure();
      return false;
    }
    await _acceptKey(dek);
    return true;
  }

  Future<void> unlockWithBiometric() async {
    await ensureLoaded();
    final config = _config;
    if (config == null) throw const FormatException('尚未设置私密书架');
    final wrapped = config.biometricWrap;
    if (wrapped == null) throw const FormatException('未启用指纹解锁');
    _checkLockout();
    final encoded = await VaultBiometric().unwrap(wrapped);
    if (encoded == null) throw const VaultLockedException('指纹验证已取消');
    final dek = base64Decode(encoded);
    if (dek.length != 32) throw const FormatException('指纹解锁数据损坏');
    await _acceptKey(dek);
  }

  Future<void> _acceptKey(List<int> dek) async {
    _cipher = VaultCipher(dek);
    _failures = 0;
    _lockUntil = 0;
    _touch();
    await db.write('DELETE FROM app_meta WHERE key=?', [guardKey]);
    notifyListeners();
  }

  void _checkLockout() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lockUntil > now) {
      final seconds = ((_lockUntil - now) / 1000).ceil();
      throw VaultLockedException('尝试次数过多，请 $seconds 秒后再试');
    }
  }

  Future<void> _recordFailure() async {
    _failures++;
    final steps = (_failures - _maxFailures).clamp(0, 4);
    final delay = _failures < _maxFailures
        ? 0
        : (30 << steps).clamp(30, 300) * 1000;
    _lockUntil = DateTime.now().millisecondsSinceEpoch + delay;
    await db.atomic(
      () async {
        await _put(
          guardKey,
          jsonEncode({'failures': _failures, 'lockUntil': _lockUntil}),
        );
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  void lock() {
    _autoLock?.cancel();
    _autoLock = null;
    if (_cipher == null) return;
    _cipher = null;
    notifyListeners();
  }

  /// Extends the idle window while encrypted records are in active use.
  void _touch() {
    if (_cipher == null) return;
    _autoLock?.cancel();
    _autoLock = Timer(_idleLock, lock);
  }

  @override
  void dispose() {
    _autoLock?.cancel();
    _cipher = null;
    super.dispose();
  }

  Future<bool> changePassword(String current, String next) async {
    await ensureLoaded();
    final config = _config;
    if (config == null || _cipher == null) throw const VaultLockedException();
    _validatePassword(next);
    final kek = await deriveVaultKey(current, base64Decode(config.salt));
    final dek = await unwrapVaultKey(config.wrappedKey, kek);
    if (dek == null) return false;
    final salt = newVaultSalt();
    final nextKek = await deriveVaultKey(next, base64Decode(salt));
    final wrapped = await wrapVaultKey(dek, nextKek);
    final updated = VaultConfig(
      salt: salt,
      wrappedKey: wrapped,
      biometricWrap: config.biometricWrap,
      hint: config.hint,
      createdAt: config.createdAt,
    );
    await db.atomic(
      () async {
        await _put(configKey, jsonEncode(updated.toJson()));
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
    _config = updated;
    // The old biometric payload still wraps the same data key.
    notifyListeners();
    return true;
  }

  Future<void> setHint(String value) async {
    await ensureLoaded();
    final config = _config;
    if (config == null) return;
    final updated = VaultConfig(
      salt: config.salt,
      wrappedKey: config.wrappedKey,
      biometricWrap: config.biometricWrap,
      hint: value.trim(),
      createdAt: config.createdAt,
    );
    await db.atomic(
      () async {
        await _put(configKey, jsonEncode(updated.toJson()));
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
    _config = updated;
    notifyListeners();
  }

  Future<bool> enableBiometric() async {
    await ensureLoaded();
    final config = _config;
    final cipher = _cipher;
    if (config == null || cipher == null) throw const VaultLockedException();
    final wrapped = await VaultBiometric().wrap(cipher.keyBytes);
    if (wrapped == null) return false;
    await _saveConfig(config.withBiometric(wrapped));
    return true;
  }

  Future<void> disableBiometric() async {
    await ensureLoaded();
    final config = _config;
    if (config == null) return;
    await _saveConfig(config.withBiometric(null));
  }

  Future<void> _saveConfig(VaultConfig config) async {
    await db.atomic(
      () async {
        await _put(configKey, jsonEncode(config.toJson()));
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
    _config = config;
    notifyListeners();
  }

  Future<String> seal(String logicalKey, Object? value) async {
    final cipher = _cipher;
    if (cipher == null) throw const VaultLockedException();
    _touch();
    return cipher.sealJson(value, aad: logicalKey);
  }

  Future<String> sealBytes(String logicalKey, List<int> value) async {
    final cipher = _cipher;
    if (cipher == null) throw const VaultLockedException();
    _touch();
    return cipher.sealBytes(value, aad: logicalKey);
  }

  /// Returns null when locked or when the payload fails authentication.
  Future<Object?> open(String logicalKey, String encoded) async {
    final cipher = _cipher;
    if (cipher == null) return null;
    _touch();
    try {
      return await cipher.openJson(encoded, aad: logicalKey);
    } on FormatException {
      return null;
    }
  }

  Future<List<int>?> openBytes(String logicalKey, String encoded) async {
    final cipher = _cipher;
    if (cipher == null) return null;
    _touch();
    return cipher.openBytes(encoded, aad: logicalKey);
  }

  Future<Object?> read(String logicalKey) async {
    final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
      '$dataPrefix$logicalKey',
    ]);
    if (rows.isEmpty) return null;
    final encoded = rows.single['value'];
    if (encoded is! String) return null;
    return open(logicalKey, encoded);
  }

  Future<void> write(String logicalKey, Object? value) async {
    final encoded = await seal(logicalKey, value);
    await db.atomic(
      () async {
        await _put('$dataPrefix$logicalKey', encoded);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> writeBytes(String logicalKey, List<int> value) async {
    final encoded = await sealBytes(logicalKey, value);
    await db.atomic(
      () async {
        await _put('$dataPrefix$logicalKey', encoded);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> delete(String logicalKey) => db.atomic(
    () async {
      await db.write('DELETE FROM app_meta WHERE key=?', [
        '$dataPrefix$logicalKey',
      ]);
    },
    tables: {'app_meta'},
    metadataDomains: {MetadataDomain.books},
  );

  Future<void> deletePrefix(String logicalKeyPrefix) => db.atomic(
    () async {
      await db.write("DELETE FROM app_meta WHERE key GLOB ?", [
        '$dataPrefix$logicalKeyPrefix*',
      ]);
    },
    tables: {'app_meta'},
    metadataDomains: {MetadataDomain.books},
  );

  Future<void> addBook(String id) => _editIndex((ids) => ids..add(id));

  Future<void> removeBook(String id) => _editIndex((ids) => ids..remove(id));

  Future<void> _editIndex(void Function(Set<String>) change) async {
    await ensureLoaded();
    final before = _ids.length;
    change(_ids);
    if (_ids.length == before) return;
    if (_ids.length > _maxBooks) {
      throw const FormatException('私密书架最多保存 5000 本书');
    }
    await db.atomic(
      () async {
        await _put(indexKey, jsonEncode(_ids.toList()));
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
    notifyListeners();
  }

  Future<void> _put(String key, String value) => db.write(
    'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
    [key, value],
  );
}

/// Native biometric confirmation plus Android Keystore wrapping.
///
/// Windows has no implementation; the UI then offers only the vault password.
final class VaultBiometric {
  const VaultBiometric();

  static const channelName = 'zero_player/vault_biometric';
  static const _channel = MethodChannel(channelName);

  Future<bool> get available async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String?> wrap(List<int> key) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<String>('wrap', {
        'key': base64Encode(key),
      });
    } on PlatformException catch (error) {
      if (error.code == 'invalidated') {
        throw const FormatException('指纹信息已变更，请重新启用指纹解锁');
      }
      return null;
    }
  }

  Future<String?> unwrap(String payload) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<String>('unwrap', {
        'payload': payload,
      });
    } on PlatformException catch (error) {
      if (error.code == 'invalidated') {
        throw const FormatException('指纹信息已变更，请使用密码解锁并重新启用');
      }
      return null;
    }
  }

  bool get _android {
    try {
      return defaultTargetPlatform == TargetPlatform.android;
    } on Object {
      return false;
    }
  }
}
