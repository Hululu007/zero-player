/// Only audited key families belong here. Other metadata remains unknown.
enum MetadataDomain {
  musicHistory,
  musicPlaylists,
  musicMode,
  live,
  books,
  musicDownloads,
  musicPreferences;

  bool accepts(String key) => switch (this) {
    musicHistory => key.startsWith('music_history:'),
    musicPlaylists => key.startsWith('music_playlist:'),
    musicMode => key == 'music_mode',
    books => key.startsWith('books_'),
    musicDownloads => key.startsWith('music_download:'),
    musicPreferences =>
      key == 'music_provider' ||
          key == 'music_source_favorites' ||
          key == 'music_discovery_homepage' ||
          key.startsWith('music_recommendation:'),
    live => const [
      'live_state:',
      'live_metadata:',
      'live_list_enabled:',
      'builtin_live_quarantined:',
    ].any(key.startsWith),
  };
}
