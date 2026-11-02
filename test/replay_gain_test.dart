import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/replay_gain.dart';

void main() {
  test('off, or no tags, means no gain', () {
    expect(
      gainFromTags({'REPLAYGAIN_TRACK_GAIN': '-6 dB'}, LevellingMode.off),
      isNull,
    );
    expect(gainFromTags({}, LevellingMode.track), isNull);
    expect(
      gainFromTags({'REPLAYGAIN_TRACK_GAIN': 'none'}, LevellingMode.track),
      isNull,
    );
  });

  test('picks the kind asked for and falls back to the other', () {
    const both = {
      'REPLAYGAIN_TRACK_GAIN': '-6.5 dB',
      'REPLAYGAIN_ALBUM_GAIN': '-3,25 dB',
    };
    expect(gainFromTags(both, LevellingMode.track), -6.5);
    expect(gainFromTags(both, LevellingMode.album), -3.25);
    expect(
      gainFromTags({'REPLAYGAIN_TRACK_GAIN': '+1 dB'}, LevellingMode.album),
      1,
    );
  });

  test('a boost stops at the peak', () {
    const tags = {
      'REPLAYGAIN_TRACK_GAIN': '+10 dB',
      'REPLAYGAIN_TRACK_PEAK': '0.5',
    };
    expect(gainFromTags(tags, LevellingMode.track), closeTo(6.02, 0.01));
  });

  test('Opus R128 gains move to the ReplayGain reference', () {
    expect(gainFromTags({'R128_TRACK_GAIN': '-512'}, LevellingMode.track), 3);
  });

  test('volume only turns down', () {
    expect(volumeForGain(6), 1);
    expect(volumeForGain(-20), closeTo(0.1, 0.0001));
  });

  test('quality label shows what is known', () {
    expect(
      qualityLabel('FLAC', {
        'bits': 24,
        'sampleRate': 96000,
        'bitrate': 2304000,
      }),
      'FLAC · 24-bit · 96 kHz · 2304 kbps',
    );
    expect(
      qualityLabel('MP3', {'sampleRate': 44100, 'bitrate': 320000, 'bits': 0}),
      'MP3 · 44.1 kHz · 320 kbps',
    );
    expect(qualityLabel('OGG', {}), 'OGG');
  });
}
