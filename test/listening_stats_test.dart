import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/listening_history.dart';
import 'package:nova_player/listening_stats.dart';

PlayRecord rec(
  String file,
  int seconds, {
  String artist = 'A',
  String genre = 'Rock',
  int length = 200000,
  DateTime? at,
}) => PlayRecord(
  start: at ?? DateTime(2026, 10, 9, 21),
  songId: file,
  fileName: file,
  title: file,
  artist: artist,
  album: 'Album',
  genre: genre,
  listenedMs: seconds * 1000,
  lengthMs: length,
);

void main() {
  test('a play counts after 30 s, or half of a short song', () {
    expect(rec('a', 29).countsAsPlay, isFalse);
    expect(rec('a', 30).countsAsPlay, isTrue);
    expect(rec('a', 10, length: 20000).countsAsPlay, isTrue);
    expect(rec('a', 9, length: 20000).countsAsPlay, isFalse);
  });

  test('ranks songs by plays and genres by time, splitting genre tags', () {
    final stats = computeStats([
      rec('one', 60, genre: 'Rock; Indie'),
      rec('one', 45),
      rec('two', 200, artist: 'B', genre: 'Ambient'),
      rec('three', 5), // skipped: time counts, play does not
    ]);
    expect(stats.plays, 3);
    expect(stats.totalMs, 310000);
    expect(stats.uniqueSongs, 3);
    expect(stats.topSongs.first.label, 'one');
    expect(stats.topSongs.first.plays, 2);
    expect(stats.topArtists.first.label, 'B');
    expect(stats.topGenres.map((g) => g.label), ['Ambient', 'Rock', 'Indie']);
    expect(stats.peakHour, 21);
  });

  test('filters by period and handles no listening', () {
    final records = [
      rec('old', 100, at: DateTime(2025, 1, 1)),
      rec('new', 100, at: DateTime(2026, 10, 1)),
    ];
    expect(computeStats(records, since: DateTime(2026)).uniqueSongs, 1);
    final empty = computeStats(const []);
    expect(empty.isEmpty, isTrue);
    expect(empty.peakHour, isNull);
    expect(empty.topDay, isNull);
  });

  test('log survives a line cut short by a crash', () {
    final good = rec('a', 40);
    final text = '${'{"t":1}'}\n${'{"t": broken'}\n';
    expect(parseHistory(text), isEmpty);
    expect(
      parseHistory(
        '{"t":${good.start.millisecondsSinceEpoch},"id":"a",'
        '"f":"a","ti":"a","ar":"A","al":"Al","g":"Rock","ms":40000,'
        '"len":200000}\n{"t": bro',
      ).single.listenedMs,
      40000,
    );
  });
}
