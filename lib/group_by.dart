import 'song.dart';

enum GroupBy { none, artist, album, genre, year, format }

extension GroupByDetails on GroupBy {
  String get label => switch (this) {
    GroupBy.none => 'None',
    GroupBy.artist => 'Artist',
    GroupBy.album => 'Album',
    GroupBy.genre => 'Genre',
    GroupBy.year => 'Year',
    GroupBy.format => 'Format',
  };

  String keyFor(Song song) => switch (this) {
    GroupBy.none => '',
    GroupBy.artist => song.artist,
    GroupBy.album => song.album,
    GroupBy.genre => song.genre,
    GroupBy.year => song.year,
    GroupBy.format => song.format,
  };
}

/// Groups sorted by key (case-insensitive); songs keep their order inside a group.
Map<String, List<Song>> groupSongs(
  List<Song> songs,
  String Function(Song song) keyFor,
) {
  final groups = <String, List<Song>>{};
  for (final song in songs) {
    groups.putIfAbsent(keyFor(song), () => []).add(song);
  }
  return Map.fromEntries(
    groups.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase())),
  );
}
