import 'publication.dart';

final class PublicationHolding {
  const PublicationHolding({
    required this.id,
    required this.edition,
    required this.digest,
    required this.format,
    required this.bytes,
    required this.resident,
    required this.kept,
    required this.added,
    this.lastRead = 0,
    this.groupId,
    this.finished = false,
    this.legacyId,
  });
  final String id, digest;
  final PublicationEdition edition;
  final PublicationFormat format;
  final int bytes, added, lastRead;
  final bool resident, kept, finished;
  final String? groupId;
  final String? legacyId;
}
