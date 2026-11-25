import '../domain/publication.dart';

typedef CloudSharedFile = ({String name, String? id, int? bytes});

final class CloudShareItem {
  const CloudShareItem(this.file, this.folders);

  final CloudSharedFile file;
  final List<String> folders;

  bool inside(List<String> directory) {
    if (folders.length < directory.length) return false;
    for (var index = 0; index < directory.length; index++) {
      if (folders[index] != directory[index]) return false;
    }
    return true;
  }
}

typedef CloudShareListing = ({List<CloudShareItem> files, bool truncated});

PublicationSharedFile? sharedPublication(CloudSharedFile file) {
  final format = PublicationFormat.fromName(file.name);
  if (format == null || (file.bytes ?? 0) > format.maxBytes) return null;
  return (name: file.name, id: file.id, format: format, bytes: file.bytes);
}
