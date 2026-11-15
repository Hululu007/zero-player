import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'legado_source.dart';

// Include every normalized request field while making map order irrelevant.
String legadoSourceFingerprint(LegadoSource source) => sha256
    .convert(utf8.encode(jsonEncode(_canonical(source.toJson()))))
    .toString();

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
