import 'song.dart';

/// [songs] as an extended M3U playlist other players can open.
String toM3u(List<Song> songs) {
  final lines = ['#EXTM3U'];
  for (final song in songs) {
    lines
      ..add('#EXTINF:${song.duration.inSeconds},${song.artist} - ${song.title}')
      ..add(song.path.isEmpty ? song.fileName : song.path);
  }
  return '${lines.join('\n')}\n';
}

/// Songs of [library] listed in an M3U [text], in order, matched by file
/// name. Entries not on the phone are skipped.
List<Song> fromM3u(String text, List<Song> library) {
  final byName = <String, Song>{};
  for (final song in library) {
    byName.putIfAbsent(song.fileName.toLowerCase(), () => song);
  }
  return [
    for (final line in text.split(RegExp(r'\r?\n')))
      if (line.trim() case final entry
          when entry.isNotEmpty && !entry.startsWith('#'))
        ?byName[_fileName(entry)],
  ];
}

/// Last path part, lower case; "%20" style escapes decoded when valid.
String _fileName(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  try {
    return Uri.decodeFull(name).toLowerCase();
  } on ArgumentError {
    return name.toLowerCase(); // a literal "%", as in "100% Love.mp3"
  }
}
