import 'book.dart';

typedef RichDocumentPosition = ({
  int index,
  bool horizontal,
  int verticalPage,
  int? sourceOffset,
  double offset,
  double fraction,
});
typedef RichDocumentNote = ({
  String id,
  int index,
  double fraction,
  String excerpt,
  String text,
});

/// Reading controls shared by the legacy and professional-document entries.
final class RichDocumentAccess {
  const RichDocumentAccess({
    required this.chapters,
    required this.isAllowed,
    required this.loadPosition,
    required this.savePosition,
    required this.loadNotes,
    required this.addNote,
    required this.deleteNote,
    this.searchable = true,
    this.password,
  });

  final List<BookChapter> chapters;
  final bool Function() isAllowed;
  final bool searchable;
  final String? password;
  final Future<RichDocumentPosition?> Function() loadPosition;
  final Future<void> Function(RichDocumentPosition) savePosition;
  final Future<List<RichDocumentNote>> Function() loadNotes;
  final Future<void> Function(
    int index,
    double fraction,
    String excerpt,
    String text,
  )
  addNote;
  final Future<void> Function(String id) deleteNote;
}
