import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/backup.dart';
import 'package:nova_player/m3u.dart';
import 'package:nova_player/song.dart';

Song song(String file) => Song(
  id: file,
  title: 'Title $file',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(seconds: 61),
  uri: Uri.parse('content://$file'),
  fileName: file,
  mimeType: '',
  path: '/storage/3738-3432/Music/$file',
);

void main() {
  test('backups keep every setting type and the history', () {
    final backup = decodeBackup(
      encodeBackup({
        'theme_id': 'hades',
        'shuffle': true,
        'position_ms': 42,
        'text_scale': 1.0,
        'queue': ['1', '2'],
      }, 'line\n'),
    );
    expect(backup.settings, {
      'theme_id': 'hades',
      'shuffle': true,
      'position_ms': 42,
      'text_scale': 1.0,
      'queue': ['1', '2'],
    });
    expect(backup.settings['text_scale'], isA<double>());
    expect(backup.history, 'line\n');
  });

  test('other files are refused', () {
    for (final text in ['', 'hello', '{"a":1}', '[1]', '{"nova_backup":2}']) {
      expect(() => decodeBackup(text), throwsFormatException, reason: text);
    }
    expect(
      () => decodeBackup(
        '{"nova_backup":1,"settings":{"x":{"y":1}},"history":""}',
      ),
      throwsFormatException,
    );
  });

  test('m3u round trip matches by file name, skipping missing songs', () {
    final library = [song('a.flac'), song('b.mp3'), song('100% Love.mp3')];
    final text = toM3u([library[1], library[0], library[2]]);
    expect(text, contains('#EXTINF:61,Artist - Title b.mp3'));
    expect(text, contains('/storage/3738-3432/Music/b.mp3'));
    expect(fromM3u(text, library), [library[1], library[0], library[2]]);
    expect(fromM3u('C:\\Music\\A.FLAC\r\nmissing.mp3\n#comment\n', library), [
      library[0],
    ]);
    expect(fromM3u('file:///x/b%2Emp3', library), [library[1]]);
  });
}
