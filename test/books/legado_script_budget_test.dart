import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:zero_player/features/books/data/legado/legado_script_budget.dart';

void main() {
  test('small repeated DOM results preserve their original HTML', () {
    final node = html
        .parseFragment('<p title="a&amp;b">普通内容</p>')
        .children
        .single;
    final converted = LegadoScriptBudget(2048).convert([node, node]) as List;
    expect(converted, [node.outerHtml, node.outerHtml]);
  });

  test('shared budget rejects repeated DOM output before growing the list', () {
    final node = html.parseFragment('<p>${'文' * 30}</p>').children.single;
    final budget = LegadoScriptBudget(700);
    expect(() => budget.convert(List.filled(20, node)), throwsFormatException);
    expect(budget.remaining, greaterThanOrEqualTo(0));
  });

  test('rejects one oversized or excessively deep DOM value', () {
    final large = html.parseFragment('<p>${'a' * 300}</p>').children.single;
    expect(() => LegadoScriptBudget(200).convert(large), throwsFormatException);
    final root = html.parseFragment('<div></div>').children.single;
    var current = root;
    for (var i = 0; i <= LegadoScriptBudget.maxDepth; i++) {
      final child = html.parseFragment('<div></div>').children.single;
      current.append(child);
      current = child;
    }
    expect(() => LegadoScriptBudget().convert(root), throwsFormatException);
  });

  test('counts JSON UTF-8 and escaping without allocating encoded output', () {
    final value = {
      'name': '中文\n"',
      'items': [1, true, null],
    };
    final length = utf8.encode(jsonEncode(value)).length;
    final budget = LegadoScriptBudget(length);
    expect(budget.chargeJson(value), length);
    expect(budget.remaining, 0);
    expect(
      () => LegadoScriptBudget(length - 1).chargeJson(value),
      throwsFormatException,
    );
  });

  test(
    'rejects deeply nested or cyclic data before recursive JSON encoding',
    () {
      Object? nested = 'value';
      for (var i = 0; i <= LegadoScriptBudget.maxDepth; i++) {
        nested = [nested];
      }
      expect(
        () => LegadoScriptBudget().chargeJson(nested),
        throwsFormatException,
      );
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      expect(
        () => LegadoScriptBudget().chargeJson(cyclic),
        throwsFormatException,
      );
    },
  );
}
