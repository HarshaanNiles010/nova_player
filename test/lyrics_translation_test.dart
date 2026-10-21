import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/lyrics.dart';
import 'package:nova_player/lyrics_translation.dart';

void main() {
  final lines = parseLyrics(
    '[00:01.50]無敵の笑顔\n[00:04.00]Muteki no egao\n[01:02.25]',
  );

  test('a saved translation reads back line for line', () {
    final lrc = translationLrc(lines, ['Invincible smile', '', '']);
    expect(
      lrc,
      '[00:01.50]Invincible smile\n[00:04.00]Muteki no egao\n[01:02.25]',
    );
    expect(readTranslation(lines, lrc), ['Invincible smile', '', '']);
  });

  test('plain lyrics keep their order without timestamps', () {
    final plain = parseLyrics('Привет\nмир');
    final lrc = translationLrc(plain, ['Hello', 'world']);
    expect(lrc, 'Hello\nworld');
    expect(readTranslation(plain, lrc), ['Hello', 'world']);
  });

  test('millisecond timestamps round into the next minute', () {
    final precise = parseLyrics('[00:59.996]Да');
    expect(translationLrc(precise, ['Yes']), '[01:00.00]Yes');
  });

  test('a translation of other lyrics is ignored', () {
    expect(readTranslation(lines, '[00:01.50]Only one line'), isNull);
  });
}
