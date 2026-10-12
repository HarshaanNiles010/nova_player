import 'dart:math' as math;

import 'listening_history.dart';
import 'listening_stats.dart';
import 'song.dart';

const smartPlaylistSize = 50;

/// Distinct songs from [history] that counted as a play, most recent first.
List<Song> recentlyPlayed(List<PlayRecord> history, List<Song> library) {
  final byKey = {for (final song in library) song.key: song};
  final seen = <String>{};
  final records = history.where((r) => r.countsAsPlay).toList()
    ..sort((a, b) => b.start.compareTo(a.start));
  return [
    for (final r in records)
      if (seen.add(r.songKey)) ?byKey[r.songKey],
  ].take(smartPlaylistSize).toList();
}

List<Song> newestSongs(List<Song> library) =>
    ([...library]..sort((a, b) => b.dateAdded.compareTo(a.dateAdded)))
        .take(smartPlaylistSize)
        .toList();

/// Random songs that never counted as a play.
List<Song> neverPlayed(
  List<PlayRecord> history,
  List<Song> library,
  math.Random random,
) {
  final played = {
    for (final r in history)
      if (r.countsAsPlay) r.songKey,
  };
  return (library.where((song) => !played.contains(song.key)).toList()
        ..shuffle(random))
      .take(smartPlaylistSize)
      .toList();
}

/// Genre name -> songs. "Post-Rock" and "post rock" are one genre, and
/// untagged songs take the genres of their artist's tagged songs.
Map<String, List<Song>> songsByGenre(List<Song> library) {
  String norm(String genre) => genre.toLowerCase().replaceAll('-', ' ');
  final spellings = <String, Map<String, int>>{};
  final artistGenres = <String, Set<String>>{};
  for (final song in library) {
    for (final genre in splitGenres(song.genre)) {
      final spelling = spellings.putIfAbsent(norm(genre), () => {});
      spelling[genre] = (spelling[genre] ?? 0) + 1;
      artistGenres.putIfAbsent(song.artist, () => {}).add(norm(genre));
    }
  }
  final groups = <String, List<Song>>{};
  for (final song in library) {
    final own = splitGenres(song.genre).map(norm).toSet();
    for (final genre in own.isEmpty ? artistGenres[song.artist] ?? {} : own) {
      groups.putIfAbsent(genre, () => []).add(song);
    }
  }
  // Shown under the most common spelling, biggest genres first.
  String label(String key) =>
      spellings[key]!.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  return {
    for (final entry
        in groups.entries.toList()
          ..sort((a, b) => b.value.length.compareTo(a.value.length)))
      label(entry.key): entry.value,
  };
}

/// Up to 50 of [candidates], best first, ranked by Thompson sampling.
///
/// Each song gets a Beta(likes, skips) belief of how likely it is to be
/// listened through. Finished plays add to likes, skips (a play that did not
/// count) to skips, both fading with a 30-day half-life so taste can change.
/// Songs never played start from their artist's like rate, so unheard songs
/// by favourite artists rank high. Ranking by a random draw from each belief
/// (instead of its average) keeps trying uncertain, new songs: Spotify's
/// home screen uses the same explore/exploit idea (BaRT).
List<Song> genreMix(
  List<Song> candidates,
  List<PlayRecord> history,
  math.Random random, {
  DateTime? now,
}) {
  const halfLifeDays = 30.0;
  const priorStrength = 4.0;
  const maxPerArtist = 4; // keeps one prolific artist from filling the mix
  final today = now ?? DateTime.now();
  final songLikes = <String, double>{}, songSkips = <String, double>{};
  final artistLikes = <String, double>{}, artistSkips = <String, double>{};
  for (final r in history) {
    final ageDays = today.difference(r.start).inHours / 24;
    final weight = math.pow(0.5, ageDays / halfLifeDays).toDouble();
    final (songs, artists) = r.countsAsPlay
        ? (songLikes, artistLikes)
        : (songSkips, artistSkips);
    songs[r.songKey] = (songs[r.songKey] ?? 0) + weight;
    artists[r.artist] = (artists[r.artist] ?? 0) + weight;
  }

  final scored = [
    for (final song in candidates)
      (
        song,
        () {
          final likes = artistLikes[song.artist] ?? 0;
          final artistRate =
              (likes + 1) / (likes + (artistSkips[song.artist] ?? 0) + 2);
          return sampleBeta(
            priorStrength * artistRate + (songLikes[song.key] ?? 0),
            priorStrength * (1 - artistRate) + (songSkips[song.key] ?? 0),
            random,
          );
        }(),
      ),
  ]..sort((a, b) => b.$2.compareTo(a.$2));

  // Spread artists first, then fill up when the genre has few artists.
  final perArtist = <String, int>{};
  final spread = [
    for (final (song, _) in scored)
      if ((perArtist[song.artist] = (perArtist[song.artist] ?? 0) + 1) <=
          maxPerArtist)
        song,
  ];
  final inSpread = spread.toSet();
  final rest = [
    for (final (song, _) in scored)
      if (!inSpread.contains(song)) song,
  ];
  return [...spread, ...rest].take(smartPlaylistSize).toList();
}

/// A draw from Beta(a, b), as X / (X + Y) with X ~ Gamma(a), Y ~ Gamma(b).
double sampleBeta(double a, double b, math.Random random) {
  final x = _sampleGamma(a, random);
  return x / (x + _sampleGamma(b, random));
}

/// Marsaglia-Tsang; shapes below 1 use Gamma(k) = Gamma(k + 1) * U^(1/k).
double _sampleGamma(double shape, math.Random random) {
  if (shape < 1) {
    return _sampleGamma(shape + 1, random) *
        math.pow(random.nextDouble(), 1 / shape);
  }
  final d = shape - 1 / 3, c = 1 / math.sqrt(9 * d);
  while (true) {
    double x, v;
    do {
      x = _normal(random);
      v = 1 + c * x;
    } while (v <= 0);
    v = v * v * v;
    final u = random.nextDouble();
    if (math.log(u) < 0.5 * x * x + d - d * v + d * math.log(v)) return d * v;
  }
}

/// Box-Muller standard normal.
double _normal(math.Random random) =>
    math.sqrt(-2 * math.log(1 - random.nextDouble())) *
    math.cos(2 * math.pi * random.nextDouble());
