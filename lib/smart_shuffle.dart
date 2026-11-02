import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'listening_history.dart';
import 'smart_playlists.dart';
import 'song.dart';

enum SmartShuffleRule {
  liked(
    'Favour songs you like',
    'Songs you finish come sooner, songs you skip come later.',
  ),
  recent(
    'Hold back recent songs',
    'Songs you played in the last few days come later.',
  ),
  artists(
    'Keep artists apart',
    'Spreads each artist through the list, and avoids the same artist '
        'within three songs when it can.',
  );

  const SmartShuffleRule(this.title, this.description);

  final String title;
  final String description;
}

/// Off plays a plain random order; every song still plays either way.
@immutable
class SmartShuffle {
  const SmartShuffle({
    this.enabled = false,
    this.rules = const {
      SmartShuffleRule.liked,
      SmartShuffleRule.recent,
      SmartShuffleRule.artists,
    },
  });

  final bool enabled;
  final Set<SmartShuffleRule> rules;
}

/// All of [songs] starting with [first], ordered by [rules] with a random draw
/// behind each song's place, so every shuffle differs.
List<Song> smartShuffled(
  List<Song> songs, {
  required Song first,
  required List<PlayRecord> history,
  required Set<SmartShuffleRule> rules,
  math.Random? random,
  DateTime? now,
}) {
  const recentHalfLifeDays = 3.0;
  final rng = random ?? math.Random();
  final today = now ?? DateTime.now();
  final draw = rules.contains(SmartShuffleRule.liked)
      ? likeSampler(history, rng, now: today)
      : (Song _) => rng.nextDouble();
  final lastPlayed = <String, DateTime>{};
  if (rules.contains(SmartShuffleRule.recent)) {
    for (final r in history) {
      final last = lastPlayed[r.songKey];
      if (r.countsAsPlay && (last == null || r.start.isAfter(last))) {
        lastPlayed[r.songKey] = r.start;
      }
    }
  }
  double hold(Song song) {
    final last = lastPlayed[song.key];
    if (last == null) return 1;
    final days = today.difference(last).inMinutes / (24 * 60);
    return 1 - math.pow(0.5, days / recentHalfLifeDays).toDouble();
  }

  final ranked = [
    for (final song in [...songs]..remove(first))
      (song, draw(song) * hold(song)),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final rest = [for (final (song, _) in ranked) song];
  return [
    first,
    ...rules.contains(SmartShuffleRule.artists)
        ? _keepArtistsApart(_spreadArtists(rest, rng), first.artist)
        : rest,
  ];
}

/// Blends each song's rank with an even spread of its artist's songs through
/// the list, so a favourite artist's songs do not all rank first.
List<Song> _spreadArtists(List<Song> ranked, math.Random random) {
  final total = <String, int>{};
  for (final song in ranked) {
    total[song.artist] = (total[song.artist] ?? 0) + 1;
  }
  final seen = <String, int>{};
  final placed = [
    for (final (rank, song) in ranked.indexed)
      () {
        final nth = seen[song.artist] ?? 0;
        seen[song.artist] = nth + 1;
        final spread = (nth + random.nextDouble()) / total[song.artist]!;
        return (song, (rank / ranked.length + spread) / 2);
      }(),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (song, _) in placed) song];
}

/// Moves each next song up past ones whose artist was just heard.
List<Song> _keepArtistsApart(List<Song> ranked, String firstArtist) {
  const gap = 3;
  const lookahead = 50; // bounds the search when one artist fills the list
  final remaining = [...ranked];
  final heard = [firstArtist];
  final order = <Song>[];
  while (remaining.isNotEmpty) {
    var pick = 0;
    for (var i = 0; i < math.min(lookahead, remaining.length); i++) {
      if (!heard.contains(remaining[i].artist)) {
        pick = i;
        break;
      }
    }
    final song = remaining.removeAt(pick);
    order.add(song);
    heard.add(song.artist);
    if (heard.length > gap) heard.removeAt(0);
  }
  return order;
}
