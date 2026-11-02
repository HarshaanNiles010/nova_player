import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/song.dart';
import 'package:nova_player/song_sort.dart';

Song song(
  String title, {
  String artist = 'A',
  String album = 'X',
  int track = 0,
  int added = 0,
  int seconds = 0,
}) => Song(
  id: title,
  title: title,
  artist: artist,
  album: album,
  duration: Duration(seconds: seconds),
  uri: Uri.parse('content://$title'),
  fileName: '$title.flac',
  mimeType: 'audio/flac',
  track: track,
  dateAdded: added,
);

List<String> titles(List<Song> songs) => [for (final s in songs) s.title];

void main() {
  test('title keeps the same list, so playback is not reloaded', () {
    final songs = [song('b'), song('a')];
    expect(identical(sortSongs(songs, SongSort.title), songs), isTrue);
  });

  test('artist runs through albums in track order', () {
    final songs = [
      song('z', artist: 'B'),
      song('two', artist: 'a', album: 'Y', track: 2),
      song('one', artist: 'A', album: 'Y', track: 1),
      song('first', artist: 'A', album: 'X', track: 9),
    ];
    expect(titles(sortSongs(songs, SongSort.artist)), [
      'first',
      'one',
      'two',
      'z',
    ]);
  });

  test('newest, longest and most played come first, ties by title', () {
    final songs = [
      song('b', added: 5, seconds: 1),
      song('a', added: 5, seconds: 1),
      song('c', added: 9, seconds: 2),
    ];
    expect(titles(sortSongs(songs, SongSort.recentlyAdded)), ['c', 'a', 'b']);
    expect(titles(sortSongs(songs, SongSort.longest)), ['c', 'a', 'b']);
    expect(
      titles(sortSongs(songs, SongSort.mostPlayed, plays: {'b.flac': 3})),
      ['b', 'a', 'c'],
    );
  });
}
