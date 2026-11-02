import 'song.dart';

enum SongSort { title, artist, album, recentlyAdded, longest, mostPlayed }

extension SongSortDetails on SongSort {
  String get label => switch (this) {
    SongSort.title => 'Title',
    SongSort.artist => 'Artist',
    SongSort.album => 'Album',
    SongSort.recentlyAdded => 'Recently added',
    SongSort.longest => 'Longest',
    SongSort.mostPlayed => 'Most played',
  };

  /// What the fast-scroll bubble shows for [song] in this order.
  String scrollLabel(Song song, Map<String, int> plays) => switch (this) {
    SongSort.title => song.indexLetter,
    SongSort.artist => indexLetterOf(song.artist),
    SongSort.album => indexLetterOf(song.album),
    SongSort.recentlyAdded =>
      song.dateAdded == 0
          ? '?'
          : DateTime.fromMillisecondsSinceEpoch(song.dateAdded)
                .toIso8601String()
                .substring(0, 7),
    SongSort.longest => '${song.duration.inMinutes} min',
    SongSort.mostPlayed => '${plays[song.key] ?? 0} plays',
  };
}

/// [songs] in [sort] order, with ties by title. [SongSort.title] returns
/// [songs] itself, which the library already keeps in title order.
List<Song> sortSongs(
  List<Song> songs,
  SongSort sort, {
  Map<String, int> plays = const {},
}) {
  if (sort == SongSort.title) return songs;
  int text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  int byAlbum(Song a, Song b) {
    final album = text(a.album, b.album);
    if (album != 0) return album;
    final artist = text(a.albumArtist, b.albumArtist);
    return artist != 0 ? artist : a.track.compareTo(b.track);
  }

  int primary(Song a, Song b) => switch (sort) {
    SongSort.title => 0,
    SongSort.artist => () {
      final artist = text(a.artist, b.artist);
      return artist != 0 ? artist : byAlbum(a, b);
    }(),
    SongSort.album => byAlbum(a, b),
    SongSort.recentlyAdded => b.dateAdded.compareTo(a.dateAdded),
    SongSort.longest => b.duration.compareTo(a.duration),
    SongSort.mostPlayed => (plays[b.key] ?? 0).compareTo(plays[a.key] ?? 0),
  };

  return [...songs]..sort((a, b) {
    final order = primary(a, b);
    return order != 0 ? order : text(a.title, b.title);
  });
}
