import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/group_by.dart';
import 'package:nova_player/look.dart';
import 'package:nova_player/search_bar_style.dart';
import 'package:nova_player/song.dart';

Song _song(String id) => Song(
  id: id,
  title: id,
  artist: 'a',
  album: 'b',
  duration: Duration.zero,
  uri: Uri.parse('content://$id'),
  fileName: '$id.flac',
  mimeType: 'audio/flac',
);

void main() {
  test('every look survives a save and load', () {
    for (final look in looks) {
      expect(LookOptions.fromJson(look.options.toJson()), look.options);
    }
  });

  test('bad or partial saves fall back to defaults', () {
    expect(LookOptions.fromJson(null), const LookOptions());
    expect(LookOptions.fromJson('not json'), const LookOptions());
    expect(LookOptions.fromJson('[1]'), const LookOptions());
    expect(
      LookOptions.fromJson('{"Seek bar": "squiggle", "Main page": "nope"}'),
      const LookOptions(seekBar: SeekBarStyle.squiggle),
    );
  });

  test('withValue changes only its own option', () {
    final options = const LookOptions()
        .withValue(ArtShape.flower)
        .withValue(SearchBarStyle.floating)
        .withValue(LookExtra.volumeSlider);
    expect(options.artShape, ArtShape.flower);
    expect(options.searchBar, SearchBarStyle.floating);
    expect(options.has(LookExtra.volumeSlider), isTrue);
    expect(options.seekBar, SeekBarStyle.bars);
    expect(
      options.withValue(LookExtra.volumeSlider, on: false).extras,
      isEmpty,
    );
  });

  test('every option has a label', () {
    for (final (_, values) in lookChoices) {
      for (final value in values) {
        expect(lookLabels.containsKey(value), isTrue, reason: '$value');
      }
    }
    for (final extra in LookExtra.values) {
      expect(lookLabels.containsKey(extra), isTrue, reason: '$extra');
    }
  });

  test('gridRows cuts song runs into rows and keeps headings', () {
    final a = _song('a'), b = _song('b'), c = _song('c'), d = _song('d');
    expect(gridRows([a, b, c, 'Group', d], 2), [
      [a, b],
      [c],
      'Group',
      [d],
    ]);
  });

  test('dominantColor favours colorful pixels over grey ones', () {
    final rgba = Uint8List.fromList([
      for (var i = 0; i < 9; i++) ...[128, 128, 128, 255],
      ...[220, 20, 20, 255],
    ]);
    final color = dominantColor(rgba);
    expect((color.r * 255).round(), greaterThan((color.g * 255).round() + 30));
    expect(dominantColor(Uint8List(0)), Colors.black);
  });

  test('look codes round-trip and reject other text', () {
    for (final look in looks) {
      expect(lookFromCode(lookCode(look.options)), look.options);
    }
    expect(lookFromCode('  ${lookCode(looks[2].options)}\n'), looks[2].options);
    expect(lookFromCode('hello'), isNull);
    expect(lookFromCode('nova-look:!!!'), isNull);
    expect(lookFromCode('nova-look:WzFd'), isNull); // "[1]", not a map
  });
}
