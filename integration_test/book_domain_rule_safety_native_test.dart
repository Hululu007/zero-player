import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/legado/legado_request.dart';
import 'package:zero_player/features/books/data/legado/legado_script.dart';
import 'package:zero_player/features/books/data/legado/legado_worker.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('reviewed token rule rejects remote code and unsuccessful bodies', (
    tester,
  ) async {
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'assets/catalogs/books/reviewed-domain-updates.json',
              ),
            )
            as Map;
    final source = BookSource.fromJson(data['updates'][0]['source'] as Map);
    final chapter = Uri.parse('https://www.deqixss.com/books/123/456.html');
    final tokenUrl =
        'https://www.deqixss.com/scripts/chapter.js.php?aid=123&cid=456&referrer=${Uri.encodeComponent(chapter.toString())}';
    const remote =
        "var chapterToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';\n"
        "var timestamp = 1794990000;\n"
        "var nonce = 'bbbbbbbb';\n"
        "var tokenUrl = 'https://www.deqixss.com/books/123/456.html';\n"
        "var SECRET_KEY = 'hidden';";
    Future<LegadoPage> evaluate(Map<String, String> documents, {Uri? uri}) =>
        runLegadoJob(
          LegadoJob(
            source,
            uri ?? chapter,
            LegadoOperation.content,
            documents: documents,
          ),
          CancellationToken(),
        );
    String? apiAddress;
    try {
      await evaluate({tokenUrl: remote});
      fail('the fixed same-site API request must be required');
    } on LegadoNeedsDocument catch (pending) {
      apiAddress = pending.address;
    }
    expect(apiAddress, isNotNull);
    final request = LegadoRequest.parse(source, chapter, apiAddress);
    expect(request.uri.host, 'www.deqixss.com');
    expect(request.uri.path, '/modules/article/ajax2.php');
    expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
    final documents = {
      tokenUrl: remote,
      apiAddress: jsonEncode({
        'status': 1,
        'data': {'content': '<p>合成测试正文</p>'},
      }),
    };
    expect((await evaluate(documents)).content, contains('合成测试正文'));
    await _rejectCases(
      (docs) => evaluate(docs),
      documents,
      tokenUrl,
      apiAddress,
      remote,
    );
    await expectLater(
      evaluate(
        documents,
        uri: Uri.parse('https://unreviewed.example/books/123/456.html'),
      ),
      throwsFormatException,
    );
  });
}

Future<void> _rejectCases(
  Future<LegadoPage> Function(Map<String, String>) evaluate,
  Map<String, String> documents,
  String tokenUrl,
  String apiAddress,
  String remote,
) async {
  for (final invalid in [
    "$remote\njava.ajax('https://unreviewed.example/execute');",
    remote.replaceAll('/123/456.html', '/123/789.html'),
    remote.replaceAll('www.deqixss.com', 'unreviewed.example'),
    "throw new Error('remote script executed');",
  ]) {
    await expectLater(
      evaluate({...documents, tokenUrl: invalid}),
      throwsFormatException,
    );
  }
  for (final invalid in [
    {'status': 0, 'message': 'not supported'},
    {
      'status': 1,
      'data': {'content': ''},
    },
    {
      'status': 1,
      'data': {'content': 42},
    },
  ]) {
    await expectLater(
      evaluate({...documents, apiAddress: jsonEncode(invalid)}),
      throwsFormatException,
    );
  }
}
