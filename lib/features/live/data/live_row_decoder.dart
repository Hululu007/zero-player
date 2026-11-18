import 'dart:convert';
import 'dart:developer' as developer;

import '../domain/live_channel.dart';
import '../domain/live_health.dart';
import '../domain/live_metadata.dart';

LiveChannel? decodeLiveChannel(Map<String, Object?> row) {
  try {
    final urls = (jsonDecode(row['urls'] as String) as List)
        .map((u) => Uri.parse(u as String))
        .toList();
    return LiveChannel(
      id: row['id'] as String,
      listId: row['list_id'] as String,
      headerOrigin: Uri.parse(row['list_url'] as String),
      name: row['name'] as String,
      group: row['group_name'] as String,
      logo: row['logo'] as String,
      tvgId: row['tvg_id'] as String,
      urls: urls,
      headers: Map<String, String>.from(jsonDecode(row['headers'] as String)),
      favorite: row['favorite'] == 1,
      recent: row['watched_at'] != null,
      watchedAt: row['watched_at'] is int
          ? DateTime.fromMillisecondsSinceEpoch(row['watched_at'] as int)
          : null,
      listName: row['list_name'] as String,
      metadata: LiveMetadata.decode(row['metadata'], urls),
      health: LiveHealth.decode(row['health'], urls),
    );
  } on FormatException {
    _report('频道');
  } on TypeError {
    _report('频道');
  } on ArgumentError {
    _report('频道');
  }
  return null;
}

EpgProgram? decodeEpgProgram(
  Map<String, Object?> row, {
  required bool matchedByName,
  required String sourceUrl,
}) {
  try {
    final start = DateTime.fromMillisecondsSinceEpoch(
      row['start_ms'] as int,
      isUtc: true,
    );
    final end = DateTime.fromMillisecondsSinceEpoch(
      row['end_ms'] as int,
      isUtc: true,
    );
    if (!end.isAfter(start)) {
      throw const FormatException('Invalid EPG interval');
    }
    return EpgProgram(
      row['channel_id'] as String,
      row['title'] as String,
      start,
      end,
      matchedByName: matchedByName,
      sourceUrl: sourceUrl,
    );
  } on FormatException {
    _report('节目');
  } on TypeError {
    _report('节目');
  } on ArgumentError {
    _report('节目');
  }
  return null;
}

void _report(String kind) =>
    developer.log('已跳过损坏的$kind记录，保留原始数据以便恢复。', name: 'live_repository');
