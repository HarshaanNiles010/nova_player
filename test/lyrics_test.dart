import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/lyrics.dart';

void main() {
  test('parses LRC timestamps, drops tags, sorts repeated stamps', () {
    final lines = parseLyrics(
      '[ti:Spore]\n[ar:Ramona Falls]\n\n'
      '[00:13.27]It couldn\'t be this galaxy is lifeless\r\n'
      '[01:02.5][00:20.00]Chorus\n'
      '[04:18.19]',
    );
    expect(lines.map((line) => line.text), [
      'It couldn\'t be this galaxy is lifeless',
      'Chorus',
      'Chorus',
      '',
    ]);
    expect(lines.first.time, const Duration(seconds: 13, milliseconds: 270));
    expect(
      lines[2].time,
      const Duration(minutes: 1, seconds: 2, milliseconds: 500),
    );
  });

  test('reads millisecond and colon-separated fractions', () {
    final lines = parseLyrics('[00:01.234]a\n[00:02:50]b');
    expect(lines.map((line) => line.time), [
      const Duration(seconds: 1, milliseconds: 234),
      const Duration(seconds: 2, milliseconds: 500),
    ]);
  });

  test('plain lyrics have no timestamps', () {
    final lines = parseLyrics('First line\n\nSecond line\n');
    expect(lines.map((line) => line.text), ['First line', 'Second line']);
    expect(lines.every((line) => line.time == null), isTrue);
  });

  test('active line follows playback position', () {
    final lines = parseLyrics('[00:01.00]a\n[00:05.00]b\n[00:09.00]c');
    expect(activeLyricIndex(lines, Duration.zero), -1);
    expect(activeLyricIndex(lines, const Duration(seconds: 5)), 1);
    expect(activeLyricIndex(lines, const Duration(minutes: 3)), 2);
    expect(
      activeLyricIndex(parseLyrics('plain'), const Duration(minutes: 1)),
      -1,
    );
  });
}
