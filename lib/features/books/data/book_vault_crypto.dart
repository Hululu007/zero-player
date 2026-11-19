import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Fixed KDF parameters. Stored values are never trusted for cost settings.
const _kdf = 'argon2id-19m-2-1-v1';
const _version = 1;

final class VaultConfig {
  const VaultConfig({
    required this.salt,
    required this.wrappedKey,
    this.biometricWrap,
    this.hint = '',
    this.createdAt = 0,
  });

  final String salt;
  final String wrappedKey;
  final String? biometricWrap;
  final String hint;
  final int createdAt;

  bool get biometricEnabled => biometricWrap != null;

  Map<String, Object?> toJson() => {
    'version': _version,
    'kdf': _kdf,
    'salt': salt,
    'wrappedKey': wrappedKey,
    'biometric': ?biometricWrap,
    if (hint.isNotEmpty) 'hint': hint,
    'createdAt': createdAt,
  };

  static VaultConfig? fromJson(Object? value) {
    if (value is! Map ||
        value['version'] != _version ||
        value['kdf'] != _kdf ||
        value['salt'] is! String ||
        value['wrappedKey'] is! String) {
      return null;
    }
    try {
      if (base64Decode(value['salt'] as String).length != 16) return null;
      if (!isVaultCipherText(value['wrappedKey'])) return null;
      final biometric = value['biometric'];
      if (biometric != null &&
          (biometric is! String ||
              biometric.isEmpty ||
              biometric.length > 4096)) {
        return null;
      }
      return VaultConfig(
        salt: value['salt'] as String,
        wrappedKey: value['wrappedKey'] as String,
        biometricWrap: biometric as String?,
        hint: value['hint'] is String ? value['hint'] as String : '',
        createdAt: value['createdAt'] is int ? value['createdAt'] as int : 0,
      );
    } on FormatException {
      return null;
    }
  }

  VaultConfig withBiometric(String? value) => VaultConfig(
    salt: salt,
    wrappedKey: wrappedKey,
    biometricWrap: value,
    hint: hint,
    createdAt: createdAt,
  );

  VaultConfig withWrappedKey(String value) => VaultConfig(
    salt: salt,
    wrappedKey: value,
    biometricWrap: biometricWrap,
    hint: hint,
    createdAt: createdAt,
  );
}

const _prefix = 'v1:';

bool isVaultCipherText(Object? value) =>
    value is String &&
    value.startsWith(_prefix) &&
    value.length > _prefix.length &&
    value.length <= 96 * 1024 * 1024;

bool isVaultKey(String key) => key.startsWith('books_vault_');

/// AES-GCM with a per-vault random data key.
final class VaultCipher {
  VaultCipher(List<int> key)
    : _bytes = List<int>.unmodifiable(key),
      _key = SecretKey(key);

  final List<int> _bytes;
  final SecretKey _key;
  static final _algorithm = AesGcm.with256bits();

  List<int> get keyBytes => _bytes;

  Future<String> sealText(String value, {required String aad}) async =>
      _encode(await _seal(utf8.encode(value), aad));

  Future<String> sealJson(Object? value, {required String aad}) =>
      sealText(jsonEncode(value), aad: aad);

  Future<String?> openText(String encoded, {required String aad}) async {
    final clear = await _open(encoded, aad);
    if (clear == null) return null;
    return utf8.decode(clear);
  }

  Future<Object?> openJson(String encoded, {required String aad}) async {
    final text = await openText(encoded, aad: aad);
    if (text == null) return null;
    return jsonDecode(text);
  }

  Future<List<int>?> openBytes(String encoded, {required String aad}) =>
      _open(encoded, aad);

  Future<String> sealBytes(List<int> value, {required String aad}) async =>
      _encode(await _seal(value, aad));

  Future<SecretBox> _seal(List<int> clear, String aad) => _algorithm.encrypt(
    clear,
    secretKey: _key,
    nonce: _randomBytes(12),
    aad: utf8.encode(aad),
  );

  Future<List<int>?> _open(String encoded, String aad) async {
    if (!isVaultCipherText(encoded)) return null;
    try {
      final raw = base64Decode(encoded.substring(_prefix.length));
      if (raw.length < 12 + 16) return null;
      final nonce = raw.sublist(0, 12);
      final mac = raw.sublist(raw.length - 16);
      final cipherText = raw.sublist(12, raw.length - 16);
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: _key,
        aad: utf8.encode(aad),
      );
      return clear;
    } on FormatException {
      return null;
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  String _encode(SecretBox box) =>
      _prefix +
      base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<List<int>> deriveVaultKey(String password, List<int> salt) =>
    Isolate.run(() async {
      final key = await Argon2id(
        memory: 19456,
        iterations: 2,
        parallelism: 1,
        hashLength: 32,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
      return key.extractBytes();
    });

Future<List<int>> randomVaultKey() async => _randomBytes(32);

Future<String> wrapVaultKey(List<int> key, List<int> kek) async {
  final box = await AesGcm.with256bits().encrypt(
    key,
    secretKey: SecretKey(kek),
    nonce: _randomBytes(12),
    aad: utf8.encode('books_vault_config:key'),
  );
  return _prefix +
      base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<List<int>?> unwrapVaultKey(String wrapped, List<int> kek) async {
  if (!isVaultCipherText(wrapped)) return null;
  try {
    final raw = base64Decode(wrapped.substring(_prefix.length));
    if (raw.length < 12 + 16 + 32) return null;
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        raw.sublist(12, raw.length - 16),
        nonce: raw.sublist(0, 12),
        mac: Mac(raw.sublist(raw.length - 16)),
      ),
      secretKey: SecretKey(kek),
      aad: utf8.encode('books_vault_config:key'),
    );
    return clear.length == 32 ? clear : null;
  } on SecretBoxAuthenticationError {
    return null;
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
}

String newVaultSalt() => base64Encode(_randomBytes(16));

List<int> _randomBytes(int count) {
  final random = Random.secure();
  return List<int>.generate(count, (_) => random.nextInt(256));
}
