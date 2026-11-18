import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/features.dart';

/// Source ledger, not a SQL parser or a proof of write coverage. Dynamic SQL,
/// helper calls and implicit database changes still require caller review.
void main() {
  final entries = <Map<String, Object?>>[];
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final parsed = parseFile(
      path: file.absolute.path,
      featureSet: FeatureSet.latestLanguageVersion(),
    );
    parsed.unit.accept(
      _Inventory(
        file.path.replaceAll('\\', '/'),
        entries,
        (offset) => parsed.lineInfo.getLocation(offset).lineNumber,
      ),
    );
  }
  entries.sort(
    (a, b) =>
        '${a['file']}:${a['line']}'.compareTo('${b['file']}:${b['line']}'),
  );
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'format': 1,
      'scope':
          'database write/transaction/notification and generic metadata helpers in lib',
      'limitations':
          'All unreviewed/dynamic/raw/batch paths remain unknown. Consult report 4.2 for callers and reload ownership.',
      'entries': entries,
    }),
  );
}

final class _Inventory extends RecursiveAstVisitor<void> {
  _Inventory(this.file, this.entries, this.line);
  final String file;
  final List<Map<String, Object?>> entries;
  final int Function(int) line;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target?.toSource() ?? '';
    final args = node.argumentList.toSource();
    final databaseCall =
        RegExp(r'(^|\.)db$').hasMatch(target) ||
        file == 'lib/core/persistence/app_database.dart';
    final metadataHelper =
        name == 'write' && (target == 'store' || target.endsWith('.store'));
    if ((databaseCall &&
            const {
              'write',
              'customStatement',
              'atomic',
              'transaction',
              'batch',
              'changed',
              'setMetadata',
              'deleteMetadata',
              'clearMusicHistory',
            }.contains(name)) ||
        metadataHelper ||
        (name == 'customStatement' && target == 'batch')) {
      entries.add({
        'file': file,
        'line': line(node.offset),
        'method': _owner(node),
        'call': '$target.$name',
        'arguments': args,
        'metadataImpact':
            const {
              'setMetadata',
              'deleteMetadata',
              'clearMusicHistory',
            }.contains(name)
            ? 'explicit-key-domain'
            : 'unknown-unless-reviewed',
      });
    }
    super.visitMethodInvocation(node);
  }

  String _owner(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is MethodDeclaration) return parent.name.lexeme;
      if (parent is FunctionDeclaration) return parent.name.lexeme;
      if (parent is ConstructorDeclaration) return parent.returnType.name;
    }
    return '<initializer>';
  }
}
