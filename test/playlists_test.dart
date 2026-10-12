import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/playlists.dart';
import 'package:nova_player/song.dart';

Song song(String id, String file) => Song.fromMap({
  'id': id,
  'title': file,
  'uri': 'content://media/$id',
  'fileName': file,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('finds songs by file name after Android re-indexes their ids', () {
    final store = PlaylistStore.instance
      ..restore(
        '{"Mix": [{"id": "1", "file": "a.flac"}, "2", '
        '{"id": "3", "file": "gone.mp3"}]}',
      );
    // a.flac got a new id; "2" is an old-format bare id; gone.mp3 was deleted.
    final library = [song('99', 'a.flac'), song('2', 'b.opus')];

    expect(store.songsOf('Mix', library).map((s) => s.fileName), [
      'a.flac',
      'b.opus',
    ]);
    expect(store.contains('Mix', library.first), isTrue);
    expect(store.lengthOf('Mix'), 3);
  });
}
