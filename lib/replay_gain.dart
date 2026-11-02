import 'dart:math' as math;

enum LevellingMode { off, track, album }

extension LevellingModeDetails on LevellingMode {
  String get title => switch (this) {
    LevellingMode.off => 'Off',
    LevellingMode.track => 'Same volume for every song',
    LevellingMode.album => 'Same volume for every album',
  };

  String get description => switch (this) {
    LevellingMode.off => 'Songs play as loud as they were made.',
    LevellingMode.track =>
      'Uses each song\'s ReplayGain tag. Best for shuffle. Songs without the '
          'tag play unchanged.',
    LevellingMode.album =>
      'Uses the ReplayGain album tag, so quiet songs stay quiet within an '
          'album. Songs without any tag play unchanged.',
  };
}

/// The tags to ask a file for; see [gainFromTags].
const replayGainKeys = [
  'REPLAYGAIN_TRACK_GAIN',
  'REPLAYGAIN_TRACK_PEAK',
  'REPLAYGAIN_ALBUM_GAIN',
  'REPLAYGAIN_ALBUM_PEAK',
  'R128_TRACK_GAIN',
  'R128_ALBUM_GAIN',
];

/// The gain in dB to play a song at, null when it has no usable tag. Falls
/// back to the other kind of tag, and never boosts past the song's peak.
double? gainFromTags(Map<String, String> tags, LevellingMode mode) {
  if (mode == LevellingMode.off) return null;
  double? number(String? text) {
    final match = RegExp(r'[-+]?\d+(\.\d+)?')
        .firstMatch((text ?? '').replaceAll(',', '.'));
    return match == null ? null : double.parse(match.group(0)!);
  }

  final kinds = mode == LevellingMode.album
      ? const ['ALBUM', 'TRACK']
      : const ['TRACK', 'ALBUM'];
  for (final kind in kinds) {
    if (number(tags['REPLAYGAIN_${kind}_GAIN']) case final gain?) {
      final peak = number(tags['REPLAYGAIN_${kind}_PEAK']);
      if (peak == null || peak <= 0) return gain;
      return math.min(gain, -20 * math.log(peak) / math.ln10);
    }
    // Opus: 1/256 dB against -23 LUFS, where ReplayGain aims for -18.
    if (number(tags['R128_${kind}_GAIN']) case final gain?) {
      return gain / 256 + 5;
    }
  }
  return null;
}

/// Player volume for [gain] dB. It cannot go above 1; the rest of a positive
/// gain goes to the loudness enhancer.
double volumeForGain(double gain) =>
    gain >= 0 ? 1 : math.pow(10, gain / 20).toDouble();

/// The audio details of a file, as far as the phone can tell.
String qualityLabel(String format, Map<String, Object?> info) {
  int? number(String key) => switch (info[key]) {
    final num value when value > 0 => value.toInt(),
    _ => null,
  };
  final bits = number('bits');
  final rate = number('sampleRate');
  final bitrate = number('bitrate');
  String khz(int hertz) {
    final text = (hertz / 1000).toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  return [
    format,
    if (bits != null) '$bits-bit',
    if (rate != null) '${khz(rate)} kHz',
    if (bitrate != null) '${(bitrate / 1000).round()} kbps',
  ].join(' · ');
}
