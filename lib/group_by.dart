import 'song.dart';

enum GroupBy { none, artist, artistAlbum, album, genre, year, format }

extension GroupByDetails on GroupBy {
  String get label => switch (this) {
    GroupBy.none => 'None',
    GroupBy.artist => 'Artist',
    GroupBy.artistAlbum => 'Artist, then album',
    GroupBy.album => 'Album',
    GroupBy.genre => 'Genre',
    GroupBy.year => 'Year',
    GroupBy.format => 'Format',
  };

  String keyFor(Song song) => switch (this) {
    GroupBy.none => '',
    GroupBy.artist || GroupBy.artistAlbum => song.artist,
    GroupBy.album => '${song.album} · ${song.albumArtist}',
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

/// Album heading inside an artist group, for [GroupBy.artistAlbum].
typedef AlbumHeading = ({String artist, String album, int count});

/// Songs, with a group-name String before each group and, for
/// [GroupBy.artistAlbum], an [AlbumHeading] before each album in an artist.
List<Object> groupRows(List<Song> songs, GroupBy groupBy) {
  if (groupBy == GroupBy.none) return songs;
  return [
    for (final artist in groupSongs(songs, groupBy.keyFor).entries) ...[
      artist.key,
      if (groupBy == GroupBy.artistAlbum)
        for (final album in groupSongs(
          artist.value,
          (s) => s.album,
        ).entries) ...[
          (artist: artist.key, album: album.key, count: album.value.length),
          ...album.value,
        ]
      else
        ...artist.value,
    ],
  ];
}
