import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/listening_history.dart';
import 'package:nova_player/listening_stats.dart';

PlayRecord record(DateTime start, {int ms = 60000, String title = 'Song'}) =>
    PlayRecord(
      start: start,
      songId: title,
      fileName: '$title.flac',
      title: title,
      artist: 'Artist',
      album: 'Album',
      genre: 'Rock',
      listenedMs: ms,
      lengthMs: 200000,
    );

void main() {
  test('years with listening, newest first', () {
    expect(
      recapYears([
        record(DateTime(2024, 3)),
        record(DateTime(2026)),
        record(DateTime(2024, 9)),
        record(DateTime(2025), ms: 0),
      ]),
      [2026, 2024],
    );
    expect(recapYears([]), isEmpty);
  });

  test('stats stop before until', () {
    final stats = computeStats(
      [
        record(DateTime(2024, 12, 31, 23, 59), title: 'old'),
        record(DateTime(2025), title: 'first'),
        record(DateTime(2025, 12, 31, 23, 59), title: 'last'),
        record(DateTime(2026), title: 'new'),
      ],
      since: DateTime(2025),
      until: DateTime(2026),
    );
    expect(stats.plays, 2);
    expect({for (final e in stats.topSongs) e.label}, {'first', 'last'});
  });
}
