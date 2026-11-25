import 'dart:convert';

import 'package:flutter/services.dart';

final class CloudResourceCatalog {
  const CloudResourceCatalog(this.source, this.categories);

  final Uri source;
  final List<CloudResourceEntry> categories;

  static Future<CloudResourceCatalog> load() async {
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'assets/catalogs/cloud/resources.json',
              ),
            )
            as Map<String, dynamic>;
    return CloudResourceCatalog(
      Uri.parse(data['source'] as String),
      CloudResourceEntry.decodeList(data['categories'] as List<dynamic>),
    );
  }
}

final class CloudResourceEntry {
  const CloudResourceEntry(
    this.name,
    this.link,
    this.rows, {
    this.updated,
    this.code,
  });

  final String name;
  final Uri? link;
  final List<CloudResourceEntry> rows;
  final DateTime? updated;
  final String? code;

  static List<CloudResourceEntry> decodeList(List<dynamic> entries) => [
    for (final row in entries.cast<Map<String, dynamic>>())
      CloudResourceEntry(
        row['name'] as String,
        row['url'] == null ? null : Uri.parse(row['url'] as String),
        decodeList((row['rows'] as List<dynamic>?) ?? const []),
        code: switch (row['code']) {
          final String code
              when RegExp(r'^[A-Za-z0-9]{1,32}$').hasMatch(code) =>
            code,
          _ => null,
        },
      ),
  ];
}
