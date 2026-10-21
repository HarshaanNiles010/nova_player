import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'lyrics.dart';

/// Why lyrics were not translated.
enum NoTranslation { english, romanized, unknownLanguage }

/// English for each of [lines], in order, translated on the phone (ML Kit).
/// The first use of a language downloads its model (about 30 MB).
Future<({List<String>? english, NoTranslation? reason})> translateLyrics(
  List<LyricLine> lines,
) async {
  final identifier = LanguageIdentifier(confidenceThreshold: 0.5);
  final String code;
  try {
    code = await identifier.identifyLanguage(
      lines.map((line) => line.text).join('\n'),
    );
  } finally {
    await identifier.close();
  }
  // Romanized text ("ja-Latn") has no translation model.
  if (code.endsWith('-Latn')) {
    return (english: null, reason: NoTranslation.romanized);
  }
  final source = BCP47Code.fromRawValue(code);
  if (source == TranslateLanguage.english) {
    return (english: null, reason: NoTranslation.english);
  }
  if (source == null) {
    return (english: null, reason: NoTranslation.unknownLanguage);
  }
  final translator = OnDeviceTranslator(
    sourceLanguage: source,
    targetLanguage: TranslateLanguage.english,
  );
  try {
    // Line by line, so each English line keeps its original's timestamp.
    final cache = <String, Future<String>>{};
    final english = await Future.wait([
      for (final line in lines)
        line.text.trim().isEmpty
            ? Future.value('')
            : cache[line.text] ??= translator.translateText(line.text),
    ]);
    return (
      english: [
        // A line the model only echoes (romaji, English lines) adds nothing.
        for (final (i, line) in lines.indexed)
          english[i].toLowerCase() == line.text.trim().toLowerCase()
              ? ''
              : english[i],
      ],
      reason: null,
    );
  } finally {
    await translator.close();
  }
}

/// [english] as an LRC file other players can open: each original line's
/// timestamp, its English, or the original where there is none.
String translationLrc(List<LyricLine> lines, List<String> english) => [
  for (final (i, line) in lines.indexed)
    '${line.time == null ? '' : '[${_stamp(line.time!)}]'}'
        '${english[i].isEmpty ? line.text : english[i]}',
].join('\n');

/// The English per line from a file made by [translationLrc], or null when it
/// does not fit [lines] (the lyrics changed since).
List<String>? readTranslation(List<LyricLine> lines, String lrc) {
  final english = parseLyrics(lrc);
  if (english.length != lines.length) return null;
  return [
    for (final (i, line) in english.indexed)
      line.text.toLowerCase() == lines[i].text.trim().toLowerCase()
          ? ''
          : line.text,
  ];
}

String _stamp(Duration time) {
  // Round to hundredths first, so 59.996 s carries to 01:00.00, not 00:60.00.
  final hundredths = (time.inMilliseconds / 10).round();
  final minutes = (hundredths ~/ 6000).toString().padLeft(2, '0');
  final seconds = (hundredths % 6000 / 100).toStringAsFixed(2).padLeft(5, '0');
  return '$minutes:$seconds';
}
