import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/listening_history.dart';
import 'package:nova_player/smart_shuffle.dart';
import 'package:nova_player/song.dart';

Song song(String file, {String artist = 'A'}) => Song(
  id: file,
  title: file,
  artist: artist,
  album: 'Album',
  duration: const Duration(minutes: 3),
  uri: Uri.parse('content://$file'),
  fileName: file,
  mimeType: 'audio/mpeg',
);

final now = DateTime(2026, 11, 2);

PlayRecord rec(String file, int seconds, Duration ago, {String artist = 'A'}) =>
    PlayRecord(
      start: now.subtract(ago),
      songId: file,
      fileName: file,
      title: file,
      artist: artist,
      album: 'Album',
      genre: '',
      listenedMs: seconds * 1000,
      lengthMs: 180000,
    );

/// Average place of [file] over many shuffles.
double place(
  String file,
  List<Song> songs,
  List<PlayRecord> history,
  Set<SmartShuffleRule> rules,
) {
  final random = math.Random(1);
  var total = 0;
  for (var i = 0; i < 300; i++) {
    final order = smartShuffled(
      songs,
      first: songs.first,
      history: history,
      rules: rules,
      random: random,
      now: now,
    );
    total += order.indexWhere((s) => s.id == file);
  }
  return total / 300;
}

void main() {
  final songs = [for (var i = 0; i < 20; i++) song('s$i', artist: 'a$i')];

  test('plays every song once, starting with the picked one', () {
    final picked = songs[7];
    for (final rules in [
      <SmartShuffleRule>{},
      SmartShuffleRule.values.toSet(),
    ]) {
      final order = smartShuffled(
        songs,
        first: picked,
        history: const [],
        rules: rules,
      );
      expect(order.first, picked);
      expect(order.map((s) => s.id).toSet().length, songs.length);
      expect(order.length, songs.length);
    }
  });

  test('liked songs come sooner, skipped songs later', () {
    final history = [
      for (var i = 0; i < 6; i++) ...[
        rec('s1', 180, Duration(days: i + 10), artist: 'a1'),
        rec('s2', 3, Duration(days: i + 10), artist: 'a2'),
      ],
    ];
    const rules = {SmartShuffleRule.liked};
    expect(
      place('s1', songs, history, rules),
      lessThan(place('s2', songs, history, rules)),
    );
  });

  test('recent songs are held back, and a skip is not a recent play', () {
    final history = [
      rec('s1', 180, const Duration(hours: 1), artist: 'a1'),
      rec('s2', 3, const Duration(hours: 1), artist: 'a2'),
    ];
    const rules = {SmartShuffleRule.recent};
    expect(place('s1', songs, history, rules), greaterThan(16));
    expect(place('s2', songs, history, rules), inInclusiveRange(7, 13));
  });

  test('keeps artists apart, and still plays one-artist lists', () {
    final mixed = [
      for (var i = 0; i < 40; i++) song('m$i', artist: 'a${i % 4}'),
    ];
    final order = smartShuffled(
      mixed,
      first: mixed.first,
      history: const [],
      rules: const {SmartShuffleRule.artists},
    );
    for (var i = 1; i < order.length; i++) {
      expect(order[i].artist, isNot(order[i - 1].artist));
    }
    final solo = [for (var i = 0; i < 5; i++) song('o$i')];
    expect(
      smartShuffled(
        solo,
        first: solo.first,
        history: const [],
        rules: const {SmartShuffleRule.artists},
      ).length,
      5,
    );
  });

  test('a favourite artist is spread out, not bunched at the front', () {
    final library = [
      for (var i = 0; i < 20; i++) song('f$i', artist: 'fav'),
      for (var i = 0; i < 1980; i++) song('o$i', artist: 'o$i'),
    ];
    final history = [
      for (var i = 0; i < 20; i++)
        for (var day = 0; day < 5; day++)
          rec('f$i', 180, Duration(days: 20 + day), artist: 'fav'),
    ];
    final random = math.Random(1);
    double favAtFront(Set<SmartShuffleRule> rules) {
      var total = 0;
      for (var i = 0; i < 20; i++) {
        total += smartShuffled(
          library,
          first: library.last,
          history: history,
          rules: rules,
          random: random,
          now: now,
        ).take(40).where((s) => s.artist == 'fav').length;
      }
      return total / 20;
    }

    expect(favAtFront(const {SmartShuffleRule.liked}), greaterThan(15));
    expect(
      favAtFront(const {SmartShuffleRule.liked, SmartShuffleRule.artists}),
      lessThan(5),
    );
  });

  test('a big library shuffles quickly', () {
    final big = [
      for (var i = 0; i < 5000; i++) song('b$i', artist: 'a${i % 300}'),
    ];
    final history = [
      for (var i = 0; i < 20000; i++)
        rec('b${i % 5000}', 180, Duration(hours: i), artist: 'a${i % 300}'),
    ];
    final clock = Stopwatch()..start();
    smartShuffled(
      big,
      first: big.first,
      history: history,
      rules: SmartShuffleRule.values.toSet(),
    );
    expect(clock.elapsedMilliseconds, lessThan(500));
  });
}
