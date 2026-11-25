import 'dart:convert';
import 'dart:io';

import 'package:zero_player/features/publications/data/publication_panda_book_sites.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/update_panda_klib.dart SAVED_COMPLETE_RANKING_HTML',
    );
    exitCode = 64;
    return;
  }
  final html = File(args.single).readAsStringSync();
  final rows = parseKlibRankingCatalogue(html).books;
  if (!html.trimRight().endsWith('</html>') || rows.length < 100) {
    throw const FormatException('Incomplete public ranking page');
  }
  File(
    'assets/catalogs/books/panda-klib-ranking.json',
  ).writeAsStringSync(jsonEncode([for (final book in rows) book.toJson()]));
  stdout.writeln('Recorded ${rows.length} titles from the public Klib ranking');
}
