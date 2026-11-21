/// Feature-local tables in the existing application database. Installed in a
/// transaction so enabling this module does not rewrite the legacy book store.
const publicationLeasesSchema =
    '''CREATE TABLE IF NOT EXISTS publication_leases(
    id TEXT PRIMARY KEY, digest TEXT NOT NULL,
    process INTEGER NOT NULL, folder TEXT, filename TEXT)''';

const publicationSchema = [
  '''CREATE TABLE IF NOT EXISTS publication_files(
    digest TEXT PRIMARY KEY, format TEXT NOT NULL, bytes INTEGER NOT NULL,
    placement TEXT, legacy_id TEXT, downloaded INTEGER NOT NULL DEFAULT 0,
    admitted TEXT, last_read INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE UNIQUE INDEX IF NOT EXISTS publication_legacy_file
    ON publication_files(legacy_id) WHERE legacy_id IS NOT NULL''',
  '''CREATE TABLE IF NOT EXISTS publication_shelf(
    id TEXT PRIMARY KEY, edition TEXT, digest TEXT NOT NULL
    REFERENCES publication_files(digest), kept INTEGER NOT NULL DEFAULT 0,
    removed INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL)''',
  '''CREATE INDEX IF NOT EXISTS publication_shelf_digest
    ON publication_shelf(digest,removed)''',
  '''CREATE TABLE IF NOT EXISTS publication_imports(
    owner TEXT PRIMARY KEY, digest TEXT NOT NULL, format TEXT NOT NULL,
    staged_name TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS publication_file_releases(
    digest TEXT PRIMARY KEY, folder TEXT NOT NULL, filename TEXT NOT NULL,
    bytes INTEGER NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS publication_legacy_releases(
    digest TEXT NOT NULL, format TEXT NOT NULL, PRIMARY KEY(digest,format))''',
  '''CREATE TABLE IF NOT EXISTS publication_positions(
    digest TEXT PRIMARY KEY REFERENCES publication_files(digest),
    data TEXT NOT NULL, updated INTEGER NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS publication_notes(
    id TEXT PRIMARY KEY, digest TEXT NOT NULL REFERENCES publication_files(digest),
    section INTEGER NOT NULL, fraction REAL NOT NULL, excerpt TEXT NOT NULL,
    text TEXT NOT NULL, created INTEGER NOT NULL)''',
  '''CREATE INDEX IF NOT EXISTS publication_notes_digest
    ON publication_notes(digest,created)''',
  '''CREATE TABLE IF NOT EXISTS publication_tasks(
    id TEXT PRIMARY KEY, edition TEXT NOT NULL, candidates TEXT NOT NULL,
    state TEXT NOT NULL, owner TEXT, generation INTEGER NOT NULL DEFAULT 0,
    selected INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0,
    total INTEGER, failures TEXT NOT NULL DEFAULT '[]', problem TEXT,
    retry_at INTEGER, result TEXT, created INTEGER NOT NULL,
    archive_kept INTEGER NOT NULL DEFAULT 0, space_shortfall TEXT)''',
  '''CREATE TABLE IF NOT EXISTS publication_space(
    owner TEXT PRIMARY KEY, allocated INTEGER NOT NULL, used INTEGER NOT NULL)''',
  publicationLeasesSchema,
  '''CREATE TABLE IF NOT EXISTS publication_transfer(
    task TEXT PRIMARY KEY, identity TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS publication_ranges(
    task TEXT NOT NULL REFERENCES publication_transfer(task) ON DELETE CASCADE,
    start INTEGER NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(task,start))''',
  '''CREATE TABLE IF NOT EXISTS publication_source_settings(
    id TEXT PRIMARY KEY, enabled INTEGER NOT NULL, spec TEXT, failure TEXT,
    checked INTEGER, synced INTEGER, revision TEXT, favorite INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE IF NOT EXISTS publication_catalog(
    source TEXT NOT NULL, id TEXT NOT NULL, searchable TEXT NOT NULL,
    isbn TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(source,id))''',
  '''CREATE TABLE IF NOT EXISTS publication_preferences(
    key TEXT PRIMARY KEY, value TEXT NOT NULL)''',
];
