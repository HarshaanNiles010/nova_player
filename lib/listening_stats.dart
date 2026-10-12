import 'listening_history.dart';

class StatEntry {
  const StatEntry(this.label, this.detail, this.plays, this.ms, this.sample);

  final String label;
  final String detail;
  final int plays;
  final int ms;

  /// A record from this entry, used to find artwork.
  final PlayRecord sample;
}

class ListeningStats {
  const ListeningStats({
    required this.totalMs,
    required this.plays,
    required this.uniqueSongs,
    required this.uniqueArtists,
    required this.daysListened,
    required this.topSongs,
    required this.topArtists,
    required this.topAlbums,
    required this.topGenres,
    required this.peakHour,
    required this.topDay,
    required this.topDayMs,
  });

  final int totalMs;
  final int plays;
  final int uniqueSongs;
  final int uniqueArtists;
  final int daysListened;
  final List<StatEntry> topSongs;
  final List<StatEntry> topArtists;
  final List<StatEntry> topAlbums;
  final List<StatEntry> topGenres;

  /// Hour of day (0-23) with the most listening, null when there is none.
  final int? peakHour;
  final DateTime? topDay;
  final int topDayMs;

  bool get isEmpty => totalMs == 0;
}

/// Splits tag strings like "Rock; Indie, Pop" into separate genres.
List<String> splitGenres(String genre) => [
  for (final part in genre.split(RegExp(r'[,;/]')))
    if (part.trim() case final name
        when name.isNotEmpty && name != 'Unknown genre')
      name,
];

ListeningStats computeStats(
  List<PlayRecord> records, {
  DateTime? since,
  int top = 5,
}) {
  final inRange = since == null
      ? records
      : records.where((r) => !r.start.isBefore(since)).toList();

  final songs = <String, _Tally>{};
  final artists = <String, _Tally>{};
  final albums = <String, _Tally>{};
  final genres = <String, _Tally>{};
  final hours = List.filled(24, 0);
  final days = <DateTime, int>{};
  var totalMs = 0;
  var plays = 0;

  for (final r in inRange) {
    final play = r.countsAsPlay ? 1 : 0;
    totalMs += r.listenedMs;
    plays += play;
    songs
        .putIfAbsent(r.songKey, () => _Tally(r.title, r.artist, r))
        .add(r, play);
    artists.putIfAbsent(r.artist, () => _Tally(r.artist, '', r)).add(r, play);
    albums
        .putIfAbsent(
          '${r.album}\u0000${r.artist}',
          () => _Tally(r.album, r.artist, r),
        )
        .add(r, play);
    for (final genre in splitGenres(r.genre)) {
      genres
          .putIfAbsent(genre.toLowerCase(), () => _Tally(genre, '', r))
          .add(r, play);
    }
    hours[r.start.hour] += r.listenedMs;
    final day = DateTime(r.start.year, r.start.month, r.start.day);
    days[day] = (days[day] ?? 0) + r.listenedMs;
  }

  // Songs rank by plays (then time); everything else by time listened.
  List<StatEntry> rank(Map<String, _Tally> tallies, {bool byPlays = false}) {
    final list = tallies.values.toList()
      ..sort(
        (a, b) => byPlays && a.plays != b.plays
            ? b.plays.compareTo(a.plays)
            : b.ms.compareTo(a.ms),
      );
    return [for (final t in list.take(top)) t.entry];
  }

  final topDay = days.entries.isEmpty
      ? null
      : days.entries.reduce((a, b) => b.value > a.value ? b : a);
  final peak = hours.indexed.reduce((a, b) => b.$2 > a.$2 ? b : a);

  return ListeningStats(
    totalMs: totalMs,
    plays: plays,
    uniqueSongs: songs.length,
    uniqueArtists: artists.length,
    daysListened: days.length,
    topSongs: rank(songs, byPlays: true),
    topArtists: rank(artists),
    topAlbums: rank(albums),
    topGenres: rank(genres),
    peakHour: totalMs == 0 ? null : peak.$1,
    topDay: topDay?.key,
    topDayMs: topDay?.value ?? 0,
  );
}

class _Tally {
  _Tally(this.label, this.detail, this.sample);

  final String label;
  final String detail;
  final PlayRecord sample;
  int plays = 0;
  int ms = 0;

  void add(PlayRecord record, int play) {
    plays += play;
    ms += record.listenedMs;
  }

  StatEntry get entry => StatEntry(label, detail, plays, ms, sample);
}
