import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/group_by.dart';
import 'package:nova_player/music_library.dart';
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

  test('albums are told apart by album artist, else by artist', () {
    Song song(String artist, String? albumArtist) => Song.fromMap({
      'id': artist,
      'artist': artist,
      'albumArtist': albumArtist,
      'album': 'Greatest Hits',
      'uri': 'content://media/$artist',
    });
    final queen = song('Queen', null);
    final abba = song('ABBA', '');
    final duet = song('Queen & David Bowie', 'Queen');

    expect(queen.albumArtist, 'Queen');
    expect(abba.albumArtist, 'ABBA');
    expect(queen.sameAlbum(abba), isFalse);
    expect(queen.sameAlbum(duet), isTrue);
    expect(GroupBy.album.keyFor(duet), 'Greatest Hits · Queen');
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

  test('artist then album puts album headings inside each artist', () {
    Song song(String id, String artist, String album, [int track = 0]) =>
        Song.fromMap({
          'id': int.parse(id),
          'title': 'Song $id',
          'artist': artist,
          'album': album,
          'track': track,
          'uri': 'content://media/$id',
        });

    final rows = groupRows([
      song('1', 'Beta', 'Two', 2),
      song('2', 'Alpha', 'Zed'),
      song('3', 'Beta', 'One'),
      song('4', 'Alpha', 'Ark'),
      song('5', 'Beta', 'Two', 1),
    ], GroupBy.artistAlbum);

    expect(
      rows.map(
        (row) => switch (row) {
          final String artist => artist,
          final AlbumHeading a => '${a.album} (${a.count})',
          final Song s => s.id,
          _ => row,
        },
      ),
      [
        'Alpha',
        'Ark (1)',
        '4',
        'Zed (1)',
        '2',
        'Beta',
        'One (1)',
        '3',
        'Two (2)',
        '5',
        '1',
      ],
    );
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

  test('tag edits apply by path, and the album artist follows the artist', () {
    final file = {
      'id': '7',
      'title': 'Track 01',
      'artist': 'Unknown',
      'album': 'Rips',
      'uri': 'content://media/7',
      'path': '/Music/Rips/01.flac',
    };
    expect(tagEditKey(file), '/Music/Rips/01.flac');
    expect(
      tagEditKey({'uri': 'content://media/8', 'path': ''}),
      'content://media/8',
    );
    final song = Song.fromMap({
      ...file,
      'title': 'Halo',
      'artist': 'Beyoncé',
      'album': 'I Am... Sasha Fierce',
    });
    expect(song.title, 'Halo');
    expect(song.albumArtist, 'Beyoncé');
  });

  test('songs without a genre borrow their artist\'s most common one', () {
    final maps = borrowArtistGenres([
      {'artist': 'A', 'genre': 'Rock'},
      {'artist': 'A', 'genre': 'Post-Rock'},
      {'artist': 'A', 'genre': 'Post-Rock'},
      {'artist': 'A', 'genre': null},
      {'artist': 'A', 'genre': '<unknown>'},
      {'artist': 'B', 'genre': ''},
    ]);
    expect(maps.map((map) => map['genre']), [
      'Rock',
      'Post-Rock',
      'Post-Rock',
      'Post-Rock',
      'Post-Rock',
      '',
    ]);
  });
}
