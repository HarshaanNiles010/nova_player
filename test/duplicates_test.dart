import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/duplicates.dart';
import 'package:nova_player/song.dart';

Song song(
  String file,
  String title, {
  String artist = 'Band',
  int seconds = 200,
  int size = 1000,
}) => Song(
  id: file,
  title: title,
  artist: artist,
  album: 'Album',
  duration: Duration(seconds: seconds),
  uri: Uri.parse('content://$file'),
  fileName: file,
  mimeType: '',
  size: size,
);

List<List<String>> files(List<List<Song>> groups) => [
  for (final group in groups) [for (final s in group) s.fileName],
];

void main() {
  test('same song in other formats groups, lossless first then bigger', () {
    final groups = findDuplicates([
      song('a.mp3', 'Song', size: 9000),
      song('a.flac', 'Song (Remastered 2011)', seconds: 201),
      song('a.opus', 'song', size: 3000),
      song('other.mp3', 'Other'),
    ]);
    expect(files(groups), [
      ['a.flac', 'a.mp3', 'a.opus'],
    ]);
  });

  test('featured artists and remaster suffixes are ignored', () {
    final groups = findDuplicates([
      song('1.mp3', 'Track - Remastered'),
      song('2.mp3', 'Track (feat. Someone)'),
      song('3.mp3', 'Track ft. Someone'),
    ]);
    expect(groups.single.length, 3);
  });

  test('different lengths, artists or live versions stay apart', () {
    expect(
      findDuplicates([
        song('1.mp3', 'Track'),
        song('2.mp3', 'Track', seconds: 260),
        song('3.mp3', 'Track', artist: 'Other band'),
        song('4.mp3', 'Track (Live)'),
      ]),
      isEmpty,
    );
  });
}
