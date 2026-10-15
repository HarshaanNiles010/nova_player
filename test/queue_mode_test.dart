import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/queue_mode.dart';

void main() {
  test('Spotify style continues after the song that started the queue', () {
    expect(
      queueResumeIndex(
        mode: QueueMode.spotify,
        anchorIndex: 4,
        lastQueuedIndex: 9,
      ),
      5,
    );
  });

  test('Strawberry style continues after the last queued song', () {
    expect(
      queueResumeIndex(
        mode: QueueMode.strawberry,
        anchorIndex: 4,
        lastQueuedIndex: 9,
      ),
      10,
    );
  });

  test('Strawberry style with a song from outside the list does not restart '
      'the list', () {
    expect(
      queueResumeIndex(
        mode: QueueMode.strawberry,
        anchorIndex: 4,
        lastQueuedIndex: -1,
      ),
      5,
    );
  });
}
