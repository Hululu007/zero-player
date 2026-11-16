import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/data/legado/legado_rules.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Legado selector bridge preserves small HTML results', (
    tester,
  ) async {
    final source = parseBookSourceRecord({
      'bookSourceName': '桥接样本',
      'bookSourceUrl': 'https://example.test/',
      'searchUrl': '/search?q={{key}}',
      'ruleContent': {'content': '@js:result'},
    });
    final rules = LegadoRules(
      source,
      source.endpoint,
      '<main><p>甲</p><p>乙</p></main>',
    );
    expect(rules.script('java.getElements("p").length', rules.root), 2);
    expect(
      rules.script('java.getStringList("p@text").join(",")', rules.root),
      '甲,乙',
    );
  });
}
