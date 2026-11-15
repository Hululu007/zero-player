// Inspect selected source rules after the real importer has normalized them.
// Local-only: never execute a Legado rule or request a website.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';

final _eval = RegExp(r'\beval\s*\(|\b(?:new\s+)?Function\s*\(');
final _commentCall = RegExp(r'eval\s*\([\s\S]{0,160}?bookSourceComment');
const _ruleKeys = {
  'ruleSearch.bookList': 'searchList',
  'ruleContent.content': 'content',
  'ruleToc.chapterList': 'chapters',
  'ruleBookInfo.wordCount': 'infoWordCount',
  'ruleSearch.wordCount': 'searchWordCount',
};

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

List<Map<String, Object>> _entries(LegadoSource source) => [
  {'path': 'legado.search', 'value': source.search},
  {'path': 'legado.library', 'value': source.library},
  for (final entry in source.rules.entries)
    {'path': 'legado.rules.${entry.key}', 'value': entry.value},
  for (var i = 0; i < source.categories.length; i++)
    {
      'path': 'legado.categories[$i].address',
      'value': source.categories[i].address,
    },
];

List<Map<String, Object>> _targets(LegadoSource source, String field) {
  if (field == 'bookSourceComment') {
    return [
      {'path': 'legado.comment', 'value': source.comment, 'role': 'metadata'},
    ];
  }
  if (field == 'exploreUrl') {
    return [
      for (var i = 0; i < source.categories.length; i++)
        if (_eval.hasMatch(source.categories[i].address))
          {
            'path': 'legado.categories[$i].address',
            'value': source.categories[i].address,
            'role': 'rule',
          },
    ];
  }
  final key = _ruleKeys[field];
  if (key == null) throw FormatException('unsupported evidence field: $field');
  return [
    {
      'path': 'legado.rules.$key',
      'value': source.rules[key] ?? '',
      'role': 'rule',
    },
  ];
}

Map<String, Object> _inspectProfile(Map profile, List rawRecords) {
  final index = profile['selected_record_index'] as int;
  final source = parseBookSourceRecord(rawRecords[index]);
  if (source.id != profile['source_id'] || source.legado == null) {
    throw FormatException('imported identity changed for record $index');
  }
  final spec = source.legado!;
  final entries = _entries(spec);
  final callers = <Map<String, Object>>[
    for (final entry in entries)
      if (_commentCall.hasMatch(entry['value'] as String))
        {
          'path': entry['path'] as String,
          'sha256': _digest(entry['value'] as String),
        },
  ];
  final normalized = <Map<String, Object>>[];
  for (final evidence in profile['evidence'] as List) {
    if (evidence['record_index'] != index) continue;
    final field = evidence['field'] as String;
    final targets = _targets(spec, field);
    if (targets.isEmpty) {
      normalized.add({
        'original_field': field,
        'raw_field_sha256': evidence['field_sha256'] as String,
        'category': evidence['category'] as String,
        'normalized': <Object>[],
      });
    } else {
      for (final target in targets) {
        final value = target['value'] as String;
        normalized.add({
          'original_field': field,
          'raw_field_sha256': evidence['field_sha256'] as String,
          'category': evidence['category'] as String,
          'path': target['path'] as String,
          'role': target['role'] as String,
          'sha256': _digest(value),
          'contains_eval_or_function': _eval.hasMatch(value),
        });
      }
    }
  }
  return {
    'source_id': source.id,
    'name': source.name,
    'host': source.endpoint.host,
    'selected_record_index': index,
    'selected_rule_evidence': normalized,
    'comment_eval_callers': callers,
    if (index == 1798)
      'selected_rule_checks': {
        'legado.library': {
          'sha256': _digest(spec.library),
          'contains_eval_or_function': _eval.hasMatch(spec.library),
        },
        'legado.comment': {
          'sha256': _digest(spec.comment),
          'contains_eval_or_function': _eval.hasMatch(spec.comment),
        },
        for (final key in ['searchList', 'content', 'infoInit', 'chapters'])
          'legado.rules.$key': {
            'sha256': _digest(spec.rules[key] ?? ''),
            'contains_eval_or_function': _eval.hasMatch(spec.rules[key] ?? ''),
          },
      },
  };
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart --packages=.dart_tool/package_config.json '
      'tool/inventory_legado_eval_normalized.dart TRIAGE OUTPUT',
    );
    exitCode = 64;
    return;
  }
  const folder = 'assets/catalogs/books/legado';
  final manifest =
      jsonDecode(File('$folder/manifest.json').readAsStringSync()) as Map;
  final archive = File('$folder/catalog.json.bz2').readAsBytesSync();
  final digest = sha256.convert(archive).toString();
  final triage = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  if (digest != manifest['archiveSha256'] ||
      digest != triage['archive_sha256']) {
    throw const FormatException('catalog digest mismatch');
  }
  final data =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive))) as Map;
  final rawRecords = data['records'] as List;
  final result = <Map<String, Object>>[
    for (final profile in (triage['source_profiles'] as List).cast<Map>())
      if (profile['classification'] == 'network_data_to_eval')
        _inspectProfile(profile, rawRecords),
  ];
  final output = {
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'archive_sha256': digest,
    'import_code_sha256': {
      for (final path in [
        'lib/features/books/data/book_import.dart',
        'lib/features/books/data/legado/legado_import.dart',
        'lib/features/books/domain/book.dart',
        'lib/features/books/domain/legado_source.dart',
      ])
        path: sha256.convert(File(path).readAsBytesSync()).toString(),
    },
    'scope':
        'selected record normalized by parseBookSourceRecord; metadata is not an entry rule, callers are separately identified; no rule executed',
    'profiles': result,
  };
  final file = File(args[1]);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${jsonEncode(output)}\n');
  stdout.writeln('normalized ${result.length} profiles; wrote ${file.path}');
}
