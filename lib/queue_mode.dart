enum QueueMode { spotify, strawberry }

extension QueueModeDetails on QueueMode {
  String get title => switch (this) {
    QueueMode.spotify => 'Spotify style',
    QueueMode.strawberry => 'Strawberry style',
  };

  String get description => switch (this) {
    QueueMode.spotify =>
      'After queued songs, continue after the track that started the queue.',
    QueueMode.strawberry =>
      'After queued songs, continue after the last queued track.',
  };
}

int queueResumeIndex({
  required QueueMode mode,
  required int anchorIndex,
  required int lastQueuedIndex,
}) {
  return switch (mode) {
    QueueMode.spotify => anchorIndex + 1,
    QueueMode.strawberry => lastQueuedIndex + 1,
  };
}
