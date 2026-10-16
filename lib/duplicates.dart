import 'song.dart';

/// Formats that keep all of the original audio.
const _lossless = {'FLAC', 'WAV', 'ALAC', 'APE', 'AIFF', 'AIF', 'WV', 'DSF'};

/// Tags that do not make a different recording: "(Remastered 2011)",
/// "- Explicit", "[Bonus Track]", and featured artists.
final _noise = RegExp(
  r'[(\[][^)\]]*\b(remaster(ed)?|explicit|bonus track|feat\.?|ft\.|featuring)\b[^)\]]*[)\]]'
  r'|\s-\s.*\b(remaster(ed)?|explicit)\b.*$'
  r'|\s(feat\.?|ft\.|featuring)\s.*$',
  caseSensitive: false,
);

String _normalise(String text) => text
    .toLowerCase()
    .replaceAll(_noise, '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Songs that look like the same recording: same title and artist once
/// tags like "(Remastered)" are ignored, and lengths within [tolerance] of
/// each other. Each group lists the best copy first: lossless before lossy,
/// then the bigger file.
List<List<Song>> findDuplicates(
  List<Song> library, {
  Duration tolerance = const Duration(seconds: 2),
}) {
  final byName = <String, List<Song>>{};
  for (final song in library) {
    final title = _normalise(song.title);
    if (title.isEmpty) continue;
    byName
        .putIfAbsent('$title\n${_normalise(song.artist)}', () => [])
        .add(song);
  }

  int rank(Song a, Song b) {
    final lossless =
        (_lossless.contains(b.format) ? 1 : 0) -
        (_lossless.contains(a.format) ? 1 : 0);
    return lossless != 0 ? lossless : b.size.compareTo(a.size);
  }

  final groups = <List<Song>>[];
  for (final songs in byName.values) {
    if (songs.length < 2) continue;
    songs.sort((a, b) => a.duration.compareTo(b.duration));
    // Lengths chain: each song within tolerance of the one before it.
    var group = [songs.first];
    for (final song in songs.skip(1)) {
      if (song.duration - group.last.duration <= tolerance) {
        group.add(song);
      } else {
        if (group.length > 1) groups.add(group);
        group = [song];
      }
    }
    if (group.length > 1) groups.add(group);
  }
  for (final group in groups) {
    group.sort(rank);
  }
  return groups..sort(
    (a, b) =>
        a.first.title.toLowerCase().compareTo(b.first.title.toLowerCase()),
  );
}
