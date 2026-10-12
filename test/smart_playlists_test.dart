import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/listening_history.dart';
import 'package:nova_player/smart_playlists.dart';
import 'package:nova_player/song.dart';

Song song(
  String file, {
  String artist = 'A',
  String genre = '',
  int added = 0,
}) => Song(
  id: file,
  title: file,
  artist: artist,
  album: 'Album',
  duration: const Duration(minutes: 3),
  uri: Uri.parse('content://$file'),
  fileName: file,
  mimeType: 'audio/mpeg',
  genre: genre.isEmpty ? 'Unknown genre' : genre,
  dateAdded: added,
);

PlayRecord rec(String file, int seconds, {String artist = 'A', int day = 1}) =>
    PlayRecord(
      start: DateTime(2026, 10, day),
      songId: file,
      fileName: file,
      title: file,
      artist: artist,
      album: 'Album',
      genre: '',
      listenedMs: seconds * 1000,
      lengthMs: 180000,
    );

void main() {
  final random = math.Random(1);

  test('recently played: distinct counted plays, newest first', () {
    final library = [song('a'), song('b'), song('c')];
    final history = [
      rec('a', 60, day: 1),
      rec('b', 60, day: 2),
      rec('a', 60, day: 3),
      rec('c', 5, day: 4),
    ];
    expect(recentlyPlayed(history, library).map((s) => s.id), ['a', 'b']);
  });

  test('newest songs sort by date added', () {
    final library = [
      song('old', added: 1),
      song('new', added: 3),
      song('mid', added: 2),
    ];
    expect(newestSongs(library).map((s) => s.id), ['new', 'mid', 'old']);
  });

  test('never played skips counted plays but keeps skipped songs', () {
    final library = [song('a'), song('b'), song('c')];
    final picked = neverPlayed([rec('a', 60), rec('b', 5)], library, random);
    expect(picked.map((s) => s.id).toSet(), {'b', 'c'});
  });

  test('genres merge spellings and untagged songs inherit their artist', () {
    final genres = songsByGenre([
      song('a', genre: 'Post-Rock'),
      song('b', genre: 'post rock; Ambient'),
      song('c', genre: 'Post-Rock'),
      song('d'), // artist A, untagged
      song('e', artist: 'B'),
    ]);
    expect(genres.keys, ['Post-Rock', 'Ambient']);
    expect(genres['Post-Rock']!.map((s) => s.id), ['a', 'b', 'c', 'd']);
    expect(genres['Ambient']!.map((s) => s.id), ['b', 'd']);
  });

  test('genre mix favours liked artists, including their unheard songs', () {
    final candidates = [
      for (var i = 0; i < 20; i++) song('loved$i', artist: 'Loved'),
      for (var i = 0; i < 20; i++) song('skipped$i', artist: 'Skipped'),
    ];
    final history = [
      for (var i = 0; i < 10; i++)
        rec('loved$i', 180, artist: 'Loved', day: 10),
      for (var i = 0; i < 10; i++)
        rec('skipped$i', 3, artist: 'Skipped', day: 10),
    ];
    var lovedFirst = 0;
    for (var run = 0; run < 50; run++) {
      final mix = genreMix(
        candidates,
        history,
        random,
        now: DateTime(2026, 10, 11),
      );
      expect(mix.length, 40);
      // Four per artist come first, then the rest still ranked.
      expect(mix.take(8).where((s) => s.artist == 'Loved').length, 4);
      if (mix.first.artist == 'Loved') lovedFirst++;
    }
    expect(lovedFirst, greaterThan(45));
  });

  test('Beta samples average a / (a + b)', () {
    var sum = 0.0;
    for (var i = 0; i < 20000; i++) {
      sum += sampleBeta(0.6, 2.4, random);
    }
    expect(sum / 20000, closeTo(0.2, 0.01));
  });
}
