import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/live/domain/live_channel.dart';
import 'package:zero_player/features/music/domain/music_track.dart';
import '../../test_support/fake_player_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reversed in [false, true]) {
    test(
      'AUD-07 application handoffs allow only one player, reverse=$reversed',
      () => _handoff(reversed),
    );
  }
}

Future<void> _handoff(bool reversed) async {
  final root = await Directory.systemTemp.createTemp('audit-audio-handoff-');
  final music = FakePlayerEngine(), radio = FakePlayerEngine();
  final services = AppServices.scoped(
    root,
    AppDatabase.memory(),
    musicEngine: () => music,
    radioEngine: () => radio,
  );
  try {
    await services.settings.load();
    await services.supervision.load();
    final track = MusicTrack(
      id: 'exact',
      title: 'Song',
      artist: '',
      url: Uri.parse('https://audio.test/exact.mp3'),
      fetchedAt: DateTime.now(),
    );
    final station = LiveChannel(
      id: 'radio',
      listId: 'audit',
      name: 'Radio',
      urls: [Uri.parse('https://radio.test/stream')],
    );
    await services.musicPlayer.select([track], 0);
    await services.radioPlayer.select(station);
    await services.musicPlayer.pause();
    await services.radioPlayer.pause();
    final operations = reversed
        ? [services.radioPlayer.toggle(), services.musicPlayer.toggle()]
        : [services.musicPlayer.toggle(), services.radioPlayer.toggle()];
    await Future.wait(operations).timeout(const Duration(seconds: 2));
    expect(services.musicPlayer.error, isNull);
    expect(services.radioPlayer.error, isNull);
    final playing = [
      music.snapshot.playing,
      radio.snapshot.playing,
    ].where((value) => value).length;
    expect(playing, 1);
    await services.pauseAudioForVideo();
    expect(music.snapshot.playing, isFalse);
    expect(radio.snapshot.playing, isFalse);
  } finally {
    await services.close();
    await root.delete(recursive: true);
  }
}
