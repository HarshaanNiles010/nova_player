import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/listening_history.dart';
import 'package:nova_player/rule_playlists.dart';
import 'package:nova_player/song.dart';

Song song(String file, {String genre = '', int added = 0, String year = ''}) =>
    Song(
      id: file,
      title: file,
      artist: 'A',
      album: 'Album',
      duration: const Duration(minutes: 3),
      uri: Uri.parse('content://$file'),
      fileName: file,
      mimeType: 'audio/mpeg',
      genre: genre.isEmpty ? 'Unknown genre' : genre,
      year: year.isEmpty ? 'Unknown year' : year,
      dateAdded: added,
    );

PlayRecord rec(String file, int seconds) => PlayRecord(
  start: DateTime(2026, 10, 1),
  songId: file,
  fileName: file,
  title: file,
  artist: 'A',
  album: 'Album',
  genre: '',
  listenedMs: seconds * 1000,
  lengthMs: 180000,
);

List<String> names(List<Song> songs) => [for (final s in songs) s.fileName];

void main() {
  final now = DateTime(2026, 10, 16);
  final library = [
    song(
      'rock-new',
      genre: 'Rock',
      added: DateTime(2026, 9, 1).millisecondsSinceEpoch,
    ),
    song(
      'rock-old',
      genre: 'Post-Rock; Ambient',
      added: DateTime(2020).millisecondsSinceEpoch,
    ),
    song('jazz', genre: 'Jazz', year: '1959'),
  ];

  List<Song> run(List<Rule> rules, {List<PlayRecord> history = const []}) =>
      applyRules(
        RulePlaylist(name: 'x', rules: rules, sort: RuleSort.newest),
        library,
        history,
        math.Random(1),
        now: now,
      );

  test('genre contains matches any genre of a song', () {
    expect(names(run(const [Rule(RuleField.genre, RuleOp.contains, 'rock')])), [
      'rock-new',
      'rock-old',
    ]);
  });

  test('all rules must match: rock, never skipped, added this year', () {
    final result = run(
      const [
        Rule(RuleField.genre, RuleOp.contains, 'rock'),
        Rule(RuleField.skips, RuleOp.atMost, '0'),
        Rule(RuleField.addedDays, RuleOp.atMost, '365'),
      ],
      history: [rec('rock-old', 5)],
    );
    expect(names(result), ['rock-new']);
  });

  test('unknown numbers and bad input never match', () {
    expect(run(const [Rule(RuleField.year, RuleOp.atMost, '2000')]).length, 1);
    expect(run(const [Rule(RuleField.year, RuleOp.atLeast, 'abc')]), isEmpty);
  });

  test('a song never played was last played long ago', () {
    final result = run(
      const [Rule(RuleField.playedDays, RuleOp.atLeast, '30')],
      history: [rec('jazz', 120)],
    );
    expect(names(result), ['rock-new', 'rock-old']);
  });

  test('playlists survive a JSON round trip', () {
    const playlist = RulePlaylist(
      name: 'Rock',
      rules: [Rule(RuleField.genre, RuleOp.isNot, 'jazz')],
      sort: RuleSort.mostPlayed,
      limit: 0,
    );
    final copy = RulePlaylist.fromJson(
      jsonDecode(jsonEncode(playlist)) as Map<String, dynamic>,
    );
    expect(copy.name, 'Rock');
    expect(copy.rules.single.op, RuleOp.isNot);
    expect(copy.sort, RuleSort.mostPlayed);
    expect(copy.limit, 0);
  });
}
