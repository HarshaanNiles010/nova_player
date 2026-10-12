import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/group_by.dart';
import 'package:nova_player/queue_mode.dart';
import 'package:nova_player/song.dart';
import 'package:nova_player/theme.dart';
import 'package:nova_player/waveform.dart';

void main() {
  test('normalizes metadata and exposes FLAC details', () {
    final song = Song.fromMap({
      'id': 42,
      'title': 'Starlight',
      'artist': '<unknown>',
      'album': 'Night Drive',
      'duration': 185000,
      'uri': 'content://media/external/audio/media/42',
      'fileName': 'starlight.flac',
      'mimeType': 'audio/flac',
    });

    expect(song.artist, 'Unknown artist');
    expect(song.format, 'FLAC');
    expect(song.durationLabel, '3:05');
    expect(song.indexLetter, 'S');
    expect(song.year, 'Unknown year');
    expect(song.genre, 'Unknown genre');
  });

  test('groups songs by key in sorted order, keeping song order', () {
    Song song(String id, String title, Object? year, String? genre) =>
        Song.fromMap({
          'id': id,
          'title': title,
          'year': year,
          'genre': genre,
          'uri': 'content://media/$id',
          'fileName': '$id.mp3',
        });

    final songs = [
      song('1', 'Alpha', 2019, 'rock'),
      song('2', 'Beta', 0, 'Ambient'),
      song('3', 'Gamma', 2019, 'Rock'),
      song('4', 'Delta', 2001, null),
    ];

    expect(songs[1].year, 'Unknown year');
    expect(songs[3].genre, 'Unknown genre');
    final byYear = groupSongs(songs, GroupBy.year.keyFor);
    expect(byYear.keys, ['2001', '2019', 'Unknown year']);
    expect(byYear['2019']!.map((s) => s.title), ['Alpha', 'Gamma']);
    expect(groupSongs(songs, GroupBy.genre.keyFor).keys, [
      'Ambient',
      'rock',
      'Rock',
      'Unknown genre',
    ]);
    expect(GroupBy.format.keyFor(songs.first), 'MP3');
  });

  test('index letter skips leading symbols and groups digits', () {
    Song titled(String title) =>
        Song.fromMap({'id': 1, 'title': title, 'uri': 'content://media/1'});

    expect(titled('"attention mon ami"').indexLetter, 'A');
    expect(titled('(deep down)').indexLetter, 'D');
    expect(titled('1979').indexLetter, '#');
    expect(titled('*').indexLetter, '#');
    expect(titled('élan').indexLetter, 'É');
  });

  test('queue modes resume from their configured positions', () {
    expect(
      queueResumeIndex(
        mode: QueueMode.spotify,
        anchorIndex: 3,
        lastQueuedIndex: 20,
      ),
      4,
    );
    expect(
      queueResumeIndex(
        mode: QueueMode.strawberry,
        anchorIndex: 3,
        lastQueuedIndex: 20,
      ),
      21,
    );
  });

  test('ships at least twenty distinct selectable themes', () {
    expect(appThemes.length, greaterThanOrEqualTo(20));
    expect(
      appThemes.map((theme) => theme.id).toSet(),
      hasLength(appThemes.length),
    );
  });

  test('builds stable normalized waveform peaks', () {
    final first = waveformPeaks('track-42', 72);
    expect(first, waveformPeaks('track-42', 72));
    expect(first, hasLength(72));
    expect(first.every((peak) => peak >= 0.18 && peak <= 1), isTrue);
    expect(waveformPeaks('track-42', 0), isEmpty);
  });
}
