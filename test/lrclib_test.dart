import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/downloads.dart';

void main() {
  test('synced lyrics win over plain, empty ones are skipped', () {
    expect(
      lrclibLyrics({'syncedLyrics': '[00:01.00]Hi', 'plainLyrics': 'Hi'}),
      '[00:01.00]Hi',
    );
    expect(lrclibLyrics({'syncedLyrics': ' ', 'plainLyrics': 'Hi'}), 'Hi');
    expect(lrclibLyrics({'instrumental': true}), isNull);
    expect(lrclibLyrics('not a record'), isNull);
  });

  test('search takes the closest length within 3 seconds', () {
    final results = [
      {'duration': 250, 'plainLyrics': 'live'},
      {'duration': 202, 'plainLyrics': 'near'},
      {'duration': 200, 'plainLyrics': 'exact'},
      {'duration': 200, 'instrumental': true},
    ];
    expect(closestLrclibLyrics(results, 200), 'exact');
    expect(closestLrclibLyrics(results, 230), isNull);
    expect(closestLrclibLyrics(null, 200), isNull);
  });
}
