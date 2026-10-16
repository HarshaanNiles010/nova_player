import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'listening_history.dart';
import 'listening_stats.dart';
import 'smart_playlists.dart';
import 'song.dart';

/// What a rule looks at. Text fields compare words, number fields compare
/// with at least / at most.
enum RuleField {
  genre('Genre'),
  artist('Artist'),
  album('Album'),
  format('Format'),
  year('Year', number: true),
  plays('Plays', number: true),
  skips('Skips', number: true),
  addedDays('Added (days ago)', number: true),
  playedDays('Last played (days ago)', number: true);

  const RuleField(this.label, {this.number = false});

  final String label;
  final bool number;
}

enum RuleOp {
  contains('has'),
  isExactly('is'),
  isNot('is not'),
  atLeast('≥'),
  atMost('≤');

  const RuleOp(this.label);

  final String label;

  static List<RuleOp> forField(RuleField field) => field.number
      ? const [atLeast, atMost]
      : const [contains, isExactly, isNot];
}

enum RuleSort {
  best('Best match'),
  random('Random'),
  newest('Newest first'),
  mostPlayed('Most played'),
  leastPlayed('Least played');

  const RuleSort(this.label);

  final String label;
}

@immutable
class Rule {
  const Rule(this.field, this.op, this.value);

  factory Rule.fromJson(Map<String, dynamic> json) => Rule(
    RuleField.values.byName(json['field'] as String),
    RuleOp.values.byName(json['op'] as String),
    json['value'] as String,
  );

  final RuleField field;
  final RuleOp op;
  final String value;

  Map<String, String> toJson() => {
    'field': field.name,
    'op': op.name,
    'value': value,
  };
}

/// A playlist kept as rules, so it updates as the library and plays change.
@immutable
class RulePlaylist {
  const RulePlaylist({
    required this.name,
    required this.rules,
    this.sort = RuleSort.best,
    this.limit = smartPlaylistSize,
  });

  factory RulePlaylist.fromJson(Map<String, dynamic> json) => RulePlaylist(
    name: json['name'] as String,
    rules: [
      for (final rule in json['rules'] as List)
        Rule.fromJson(rule as Map<String, dynamic>),
    ],
    sort: RuleSort.values.byName(json['sort'] as String),
    limit: json['limit'] as int,
  );

  final String name;

  /// A song must match every rule.
  final List<Rule> rules;
  final RuleSort sort;

  /// Most songs to keep; 0 keeps them all.
  final int limit;

  Map<String, Object> toJson() => {
    'name': name,
    'rules': rules,
    'sort': sort.name,
    'limit': limit,
  };
}

/// Songs of [library] matching all of [playlist]'s rules, sorted and cut to
/// its limit.
List<Song> applyRules(
  RulePlaylist playlist,
  List<Song> library,
  List<PlayRecord> history,
  math.Random random, {
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final plays = <String, int>{}, skips = <String, int>{};
  final lastPlayed = <String, DateTime>{};
  for (final r in history) {
    final counts = r.countsAsPlay ? plays : skips;
    counts[r.songKey] = (counts[r.songKey] ?? 0) + 1;
    if (r.countsAsPlay && !(lastPlayed[r.songKey]?.isAfter(r.start) ?? false)) {
      lastPlayed[r.songKey] = r.start;
    }
  }

  /// The song's value for a number field; null when unknown, which never
  /// matches.
  int? numberOf(Song song, RuleField field) => switch (field) {
    RuleField.year => int.tryParse(song.year),
    RuleField.plays => plays[song.key] ?? 0,
    RuleField.skips => skips[song.key] ?? 0,
    RuleField.addedDays =>
      song.dateAdded == 0
          ? null
          : today
                .difference(DateTime.fromMillisecondsSinceEpoch(song.dateAdded))
                .inDays,
    // Never played counts as played infinitely long ago.
    RuleField.playedDays => switch (lastPlayed[song.key]) {
      final at? => today.difference(at).inDays,
      null => 1 << 30,
    },
    _ => null,
  };

  List<String> wordsOf(Song song, RuleField field) => switch (field) {
    RuleField.genre => splitGenres(song.genre),
    RuleField.artist => [song.artist],
    RuleField.album => [song.album],
    RuleField.format => [song.format],
    _ => const [],
  };

  bool matches(Song song, Rule rule) {
    final value = rule.value.trim().toLowerCase();
    if (rule.field.number) {
      final number = numberOf(song, rule.field);
      final limit = int.tryParse(value);
      if (number == null || limit == null) return false;
      return rule.op == RuleOp.atLeast ? number >= limit : number <= limit;
    }
    final words = wordsOf(song, rule.field).map((w) => w.toLowerCase());
    return switch (rule.op) {
      RuleOp.contains => words.any((w) => w.contains(value)),
      RuleOp.isExactly => words.contains(value),
      RuleOp.isNot => !words.contains(value),
      _ => false,
    };
  }

  final matching = [
    for (final song in library)
      if (playlist.rules.every((rule) => matches(song, rule))) song,
  ];
  final limit = playlist.limit > 0 ? playlist.limit : matching.length;
  final sorted = switch (playlist.sort) {
    RuleSort.best => genreMix(
      matching,
      history,
      random,
      now: today,
      limit: limit,
    ),
    RuleSort.random => matching..shuffle(random),
    RuleSort.newest =>
      matching..sort((a, b) => b.dateAdded.compareTo(a.dateAdded)),
    RuleSort.mostPlayed =>
      matching
        ..sort((a, b) => (plays[b.key] ?? 0).compareTo(plays[a.key] ?? 0)),
    RuleSort.leastPlayed =>
      matching
        ..sort((a, b) => (plays[a.key] ?? 0).compareTo(plays[b.key] ?? 0)),
  };
  return sorted.take(limit).toList();
}

/// The user's rule playlists, saved in shared preferences.
class RulePlaylistStore extends ChangeNotifier {
  RulePlaylistStore._();

  static final instance = RulePlaylistStore._().._load();

  static const _key = 'rule_playlists';
  List<RulePlaylist> _playlists = [];

  List<RulePlaylist> get playlists => List.unmodifiable(_playlists);

  Future<void> _load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      _playlists = [
        for (final json in jsonDecode(raw) as List)
          RulePlaylist.fromJson(json as Map<String, dynamic>),
      ];
    } catch (_) {
      // Unreadable data from an older version: start empty.
    }
    notifyListeners();
  }

  /// Saves [playlist], replacing the one called [replacing] (or its own name).
  Future<void> save(RulePlaylist playlist, {String? replacing}) async {
    final at = _playlists.indexWhere(
      (p) => p.name == (replacing ?? playlist.name),
    );
    _playlists.removeWhere(
      (p) => p.name == playlist.name || p.name == replacing,
    );
    _playlists.insert(
      at < 0 ? _playlists.length : math.min(at, _playlists.length),
      playlist,
    );
    await _write();
  }

  Future<void> delete(String name) async {
    _playlists.removeWhere((p) => p.name == name);
    await _write();
  }

  Future<void> _write() async {
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(_playlists),
    );
  }
}
