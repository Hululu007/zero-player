import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const folder = 'android/app/src/main/kotlin/dev/zeroplayer/zero_player';

  test('activity-result request codes are unique and centrally declared', () {
    final source = File('$folder/ActivityRequestCodes.kt').readAsStringSync();
    final entries = RegExp(
      r'^\s*const val (\w+) = (\d+)\s*$',
      multiLine: true,
    ).allMatches(source);
    final codes = {
      for (final match in entries) match[1]!: int.parse(match[2]!),
    };
    expect(codes.keys.toSet(), {
      'SAVE_FILE',
      'VIDEO_DIRECTORY',
      'VIDEO_FILE',
      'PROTECTED_BOOK_EXPORT',
      'PUBLICATION_FILE',
    });
    expect(codes.values.toSet().length, codes.length);
    expect(codes['PROTECTED_BOOK_EXPORT'], isNot(codes['VIDEO_FILE']));
  });

  test('each picker launches and accepts only its assigned request code', () {
    final main = File('$folder/MainActivity.kt').readAsStringSync();
    final video = File('$folder/VideoFilePicker.kt').readAsStringSync();
    final directory = File(
      '$folder/VideoDirectoryBridge.kt',
    ).readAsStringSync();
    final books = File('$folder/ProtectedBookExport.kt').readAsStringSync();
    final publications = File(
      '$folder/PublicationFilePicker.kt',
    ).readAsStringSync();
    expect(main, contains('ActivityRequestCodes.validate()'));
    expect(
      main,
      contains(
        'startActivityForResult(intent, ActivityRequestCodes.SAVE_FILE)',
      ),
    );
    expect(main, contains('requestCode != ActivityRequestCodes.SAVE_FILE'));
    for (final pair in [
      (video, 'VIDEO_FILE'),
      (directory, 'VIDEO_DIRECTORY'),
      (books, 'PROTECTED_BOOK_EXPORT'),
      (publications, 'PUBLICATION_FILE'),
    ]) {
      expect(pair.$1, contains('ActivityRequestCodes.${pair.$2})'));
      expect(
        pair.$1,
        matches(
          RegExp('(?:code|requestCode) != ActivityRequestCodes\\.${pair.$2}'),
        ),
      );
      expect(RegExp(r'\b72\d{2}\b').hasMatch(pair.$1), isFalse);
    }
    expect(
      books,
      contains('finishActivity(ActivityRequestCodes.PROTECTED_BOOK_EXPORT)'),
    );
  });
}
