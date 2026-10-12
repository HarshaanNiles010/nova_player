class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.uri,
    required this.fileName,
    required this.mimeType,
    this.genre = 'Unknown genre',
    this.year = 'Unknown year',
    this.dateAdded = 0,
  });

  factory Song.fromMap(Map<String, dynamic> map) {
    String clean(Object? value, String fallback) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty || text == '<unknown>' ? fallback : text;
    }

    return Song(
      id: map['id'].toString(),
      title: clean(map['title'], 'Unknown title'),
      artist: clean(map['artist'], 'Unknown artist'),
      album: clean(map['album'], 'Unknown album'),
      duration: Duration(milliseconds: (map['duration'] as num?)?.toInt() ?? 0),
      uri: Uri.parse(map['uri'].toString()),
      fileName: clean(map['fileName'], ''),
      mimeType: clean(map['mimeType'], ''),
      genre: clean(map['genre'], 'Unknown genre'),
      year: switch ((map['year'] as num?)?.toInt()) {
        final int year when year > 0 => '$year',
        _ => 'Unknown year',
      },
      dateAdded: (map['dateAdded'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Uri uri;
  final String fileName;
  final String mimeType;
  final String genre;
  final String year;

  /// When the file was added to the phone, in epoch milliseconds (0 if unknown).
  final int dateAdded;

  /// Identifies the song across re-indexing, like [PlayRecord.songKey].
  String get key => fileName.isNotEmpty ? fileName : id;

  String get format {
    final dot = fileName.lastIndexOf('.');
    if (dot >= 0 && dot < fileName.length - 1) {
      return fileName.substring(dot + 1).toUpperCase();
    }
    final slash = mimeType.lastIndexOf('/');
    return slash >= 0 ? mimeType.substring(slash + 1).toUpperCase() : 'AUDIO';
  }

  /// Fast-scroll section: first letter of the title, '#' for digits/symbols.
  String get indexLetter => indexLetterOf(title);

  String get durationLabel {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// First letter of [text] ignoring leading symbols; '#' for digits/symbols.
String indexLetterOf(String text) {
  final match = RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(text);
  final char = match?.group(0)?.toUpperCase() ?? '#';
  return RegExp(r'\p{L}', unicode: true).hasMatch(char) ? char : '#';
}
