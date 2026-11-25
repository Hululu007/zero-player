final _archiveStorage = RegExp(
  r'^(?:ia|dn)[0-9]{4,8}(?:\.[a-z]{2})?\.archive\.org$',
);

bool archivePublicationStorageHost(String host) =>
    _archiveStorage.hasMatch(host);

bool archivePublicationHost(String host) =>
    host == 'archive.org' || archivePublicationStorageHost(host);
