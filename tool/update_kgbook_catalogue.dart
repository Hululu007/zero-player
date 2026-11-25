import 'dart:convert';
import 'dart:io';

import 'package:zero_player/features/publications/data/publication_kgbook_rows.dart';

/// Input files are captured public category pages named `kg-<category>-<n>.capture`.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'dart run tool/update_kgbook_catalogue.dart <capture directory>',
    );
    exitCode = 64;
    return;
  }
  final rows = <String, List<String>>{};
  for (final category in kgbookCategories) {
    Uri? address = kgbookListing(category);
    for (var number = 1; address != null; number++) {
      if (number > 40) throw StateError('Too many pages for $category');
      final file = File('${args.single}/kg-$category-$number.capture');
      if (!file.existsSync()) {
        stderr.writeln('Missing capture for $category page $number');
        break;
      }
      final result = parseKgbookCatalogue(file.readAsStringSync(), address);
      if (result.editions.isEmpty) throw FormatException('Empty page: $file');
      for (final book in result.editions) {
        rows[book.page!.path] = [
          book.page!.path,
          book.title,
          book.author,
          book.candidates.firstOrNull?.format.name ?? '',
        ];
      }
      address = result.next;
    }
  }
  if (rows.isEmpty) throw const FormatException('No catalogue rows captured');
  File(
    kgbookIndexAsset,
  ).writeAsStringSync('${jsonEncode(rows.values.toList())}\n');
  stdout.writeln('${rows.length} catalogue records');
}
