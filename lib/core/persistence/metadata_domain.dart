/// Only audited key families belong here. Other metadata remains unknown.
enum MetadataDomain {
  musicHistory,
  musicPlaylists,
  musicMode,
  live;

  bool accepts(String key) => switch (this) {
    musicHistory => key.startsWith('music_history:'),
    musicPlaylists => key.startsWith('music_playlist:'),
    musicMode => key == 'music_mode',
    live => const [
      'live_state:',
      'live_metadata:',
      'live_list_enabled:',
      'builtin_live_quarantined:',
    ].any(key.startsWith),
  };
}
