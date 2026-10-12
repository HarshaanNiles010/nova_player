class LyricLine {
  const LyricLine(this.time, this.text);

  /// Null when the lyrics have no timestamps.
  final Duration? time;
  final String text;
}

final _timestamp = RegExp(r'\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]');

/// Parses LRC ("[mm:ss.xx]text"); text without timestamps becomes plain lines.
/// Metadata tags like [ar:...] are dropped.
List<LyricLine> parseLyrics(String raw) {
  final timed = <LyricLine>[];
  final plain = <LyricLine>[];
  for (final line in raw.replaceAll('\r', '').split('\n')) {
    final stamps = _timestamp.allMatches(line).toList();
    if (stamps.isEmpty) {
      final trimmed = line.trim();
      final isTag = RegExp(r'^\[[a-zA-Z]+:.*\]$').hasMatch(trimmed);
      if (trimmed.isNotEmpty && !isTag) plain.add(LyricLine(null, trimmed));
      continue;
    }
    final text = line.substring(stamps.last.end).trim();
    for (final stamp in stamps) {
      final seconds = double.parse(stamp.group(2)!.replaceAll(':', '.'));
      timed.add(
        LyricLine(
          Duration(
            minutes: int.parse(stamp.group(1)!),
            milliseconds: (seconds * 1000).round(),
          ),
          text,
        ),
      );
    }
  }
  if (timed.isEmpty) return plain;
  return timed..sort((a, b) => a.time!.compareTo(b.time!));
}

/// Index of the line being sung at [position], or -1 before the first line.
int activeLyricIndex(List<LyricLine> lines, Duration position) {
  var active = -1;
  for (var i = 0; i < lines.length; i++) {
    final time = lines[i].time;
    if (time == null || time > position) break;
    active = i;
  }
  return active;
}
