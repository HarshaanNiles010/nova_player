import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'listening_history.dart';
import 'music_library.dart';
import 'queue_mode.dart';
import 'song.dart';

class PlayerController extends ChangeNotifier {
  PlayerController({ListeningHistory? history})
    : _history = history ?? ListeningHistory.instance {
    _subscriptions.addAll([
      player.currentIndexStream.listen(_onIndexChanged),
      player.playerStateStream.listen((_) {
        _syncListenClock();
        notifyListeners();
      }),
      // A song finishing (including Repeat One restarting it) ends a session.
      player.positionDiscontinuityStream.listen((event) {
        if (event.reason == PositionDiscontinuityReason.autoAdvance) {
          _trackListening(restart: true);
          // Not from inside the player's own event: pause() would wait
          // on a stream that cannot fire until this callback returns.
          if (_sleepAfterSong) Timer.run(_sleepNow);
        }
      }),
      player.loopModeStream.listen((_) => notifyListeners()),
      player.shuffleModeEnabledStream.listen((_) => notifyListeners()),
    ]);
    addListener(_syncWidget);
    _checkpoint = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _savePendingListen(),
    );
  }

  final ListeningHistory _history;
  static const _channel = MethodChannel('com.novaplayer/music_library');
  String? _widgetState;
  final _listenClock = Stopwatch();
  Song? _listenSong;
  DateTime? _listenStart;
  late final Timer _checkpoint;

  /// Android's equalizer on the player's output; null on other platforms.
  final AndroidEqualizer? equalizer =
      defaultTargetPlatform == TargetPlatform.android
      ? AndroidEqualizer()
      : null;
  late final AudioPlayer player = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [?equalizer]),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<Song> _activeSequence = [];
  final List<Song> _queue = [];
  List<Song> songs = const [];

  /// Every song on the phone; [songs] may be just an album or playlist.
  List<Song> library = const [];
  QueueMode queueMode = QueueMode.spotify;
  int? _queueStart;
  int? _queueEnd;
  int? _anchorBaseIndex;
  bool _hasSelection = false;
  bool _baseSequence = true;

  /// Play order: [songs], or a shuffled copy of them. The player's own
  /// shuffle stays off so queued songs can sit right after the current one.
  List<Song> _order = const [];
  bool shuffleEnabled = false;

  /// The playing song while songs move around it. Index changes from that
  /// are not mistaken for playback leaving the queue, and [currentSong]
  /// keeps returning it while the player's index catches up.
  Song? _rearranging;

  /// iOS sets up every song handed to its player at once, which makes each
  /// play or queue change take seconds with a big list. There the player
  /// holds a window of [_order] around the playing song, extended as
  /// playback nears its end; elsewhere it holds all of it.
  static final int? _window = defaultTargetPlatform == TargetPlatform.iOS
      ? 40
      : null;

  /// [_order] songs from here on are not in the player yet.
  int _loadedEnd = 0;

  /// Queue saved from the last session, played after the next song started.
  List<Song> _restoredQueue = const [];

  DateTime? _sleepAt;
  bool _sleepAfterSong = false;
  Timer? _sleepTicker;
  static const _sleepFade = Duration(seconds: 10);

  Song? get currentSong {
    if (!_hasSelection) return null;
    if (_rearranging case final song?) return song;
    final index = player.currentIndex;
    return index == null || index < 0 || index >= _activeSequence.length
        ? null
        : _activeSequence[index];
  }

  List<Song> get upcomingQueue {
    if (!_hasSelection) return List.unmodifiable(_restoredQueue);
    if (_queueStart == null || _queue.isEmpty) return const [];
    return List.unmodifiable(_queue.skip(_consumedCount()));
  }

  /// Sequence indices that play after the current song. Queued songs come
  /// first.
  List<int> get _upNextIndices {
    final current = player.currentIndex;
    if (currentSong == null || current == null) return const [];
    final order = player.effectiveIndices;
    final at = order.indexOf(current);
    if (at < 0) return const [];
    return [
      ...order.sublist(at + 1),
      // Repeat all wraps around to the start of the list.
      if (player.loopMode == LoopMode.all) ...order.sublist(0, at),
    ];
  }

  /// Everything that will play after the current song, queued songs first.
  List<Song> get upNext => [
    for (final index in _upNextIndices) _activeSequence[index],
  ];

  /// Jumps straight to [upNext]`[index]`.
  Future<void> playUpNext(int index) async {
    final indices = _upNextIndices;
    if (index < 0 || index >= indices.length) return;
    final queued = upcomingQueue.length;
    if (index < queued) {
      // Queued songs above the tapped one stay queued and play after it.
      await moveUpcoming(index, 0);
      await player.seek(Duration.zero, index: _queueStart! + _consumedCount());
    } else if (queued > 0) {
      // Jumping past the queue keeps it: the queued songs play next.
      // shortcut: a song listed twice resolves to its first copy, map
      // sequence positions to list positions if that ever matters.
      await _startAt(_order.indexOf(_activeSequence[indices[index]]));
      return;
    } else {
      await player.seek(Duration.zero, index: indices[index]);
    }
    unawaited(player.play());
  }

  /// Queued songs already played (or playing) since the queue started.
  int _consumedCount() {
    final start = _queueStart;
    final current = player.currentIndex;
    return start != null && current != null && current >= start
        ? (current - start + 1).clamp(0, _queue.length)
        : 0;
  }

  Future<void> setSongs(List<Song> value) async {
    songs = library = value;
    if (_hasSelection) {
      // Replacing the sources would stop playback; the next playAt loads [songs].
      _baseSequence = false;
      await _refreshTags(value);
      notifyListeners();
      return;
    }
    _order = value;
    _activeSequence
      ..clear()
      ..addAll(_orderSlice(0, 0));
    await player.setAudioSources(
      _activeSequence.map(_source).toList(growable: false),
      preload: false,
      shuffleOrder: _InOrder(),
    );
    notifyListeners();
  }

  /// Plays [baseIndex] of [order] (default: current [songs]); a new order
  /// becomes the base sequence so next/previous follow what the user sees.
  /// With shuffle on, the rest of the list is shuffled after that song.
  /// [autoplay] false loads it paused at [position], to resume a session.
  Future<void> playAt(
    int baseIndex, {
    List<Song>? order,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    if (order != null && !identical(order, songs)) songs = order;
    if (shuffleEnabled) {
      _order = _shuffled(songs, first: songs[baseIndex]);
      _baseSequence = false;
      await _startAt(0, position: position, autoplay: autoplay);
    } else {
      if (!identical(_order, songs)) {
        _order = songs;
        _baseSequence = false;
      }
      await _startAt(baseIndex, position: position, autoplay: autoplay);
    }
  }

  /// Plays [orderIndex] of [_order], keeping the songs still queued.
  Future<void> _startAt(
    int orderIndex, {
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    // Songs still waiting in the queue play right after the new song.
    final queued = upcomingQueue.toList();
    _restoredQueue = const [];
    _clearQueueState();
    final reload =
        !_baseSequence ||
        // An idle player drops seek(index:), so the first play would start at track 0.
        player.processingState == ProcessingState.idle ||
        orderIndex >= _activeSequence.length;
    if (queued.isNotEmpty || reload) orderIndex = _rebase(orderIndex);
    if (queued.isNotEmpty) {
      await _startWithQueue(orderIndex, queued, position);
    } else if (reload) {
      _activeSequence
        ..clear()
        ..addAll(_orderSlice(0, orderIndex));
      await player.setAudioSources(
        _activeSequence.map(_source).toList(growable: false),
        initialIndex: orderIndex,
        initialPosition: position,
        shuffleOrder: _InOrder(),
      );
      _baseSequence = true;
    } else {
      await player.seek(position, index: orderIndex);
    }
    _hasSelection = true;
    _trackListening();
    notifyListeners();
    // just_audio's play future completes only after playback pauses or ends.
    if (autoplay) unawaited(player.play());
  }

  /// Plays [_order] up to [baseIndex], then [queued], then the rest of
  /// [_order], starting at [baseIndex].
  Future<void> _startWithQueue(
    int baseIndex,
    List<Song> queued,
    Duration position,
  ) async {
    _queue.addAll(queued);
    _anchorBaseIndex = baseIndex;
    _queueStart = baseIndex + 1;
    _queueEnd = baseIndex + queued.length;
    final resume = _resumeIndex();
    _activeSequence
      ..clear()
      ..addAll([
        ..._order.take(baseIndex + 1),
        ...queued,
        ..._orderSlice(resume, resume),
      ]);
    await player.setAudioSources(
      _activeSequence.map(_source).toList(growable: false),
      initialIndex: baseIndex,
      initialPosition: position,
      shuffleOrder: _InOrder(),
    );
    _baseSequence = false;
  }

  Future<void> addToQueue(Song song) async {
    if (currentSong == null) {
      await playAt(songs.indexOf(song));
      return;
    }
    if (_queueStart == null) {
      _anchorBaseIndex = _order.indexWhere(
        (candidate) => candidate.id == currentSong!.id,
      );
      _queueStart = player.currentIndex! + 1;
      _queueEnd = _queueStart! - 1;
    }

    final insertAt = _queueEnd! + 1;
    _queue.add(song);
    _activeSequence.insert(insertAt, song);
    await player.insertAudioSource(insertAt, _source(song));
    _queueEnd = insertAt;
    _baseSequence = false;
    await _replaceResumeTail();
    notifyListeners();
  }

  Future<void> removeUpcomingAt(int index) async {
    final start = _queueStart;
    final current = player.currentIndex;
    if (start == null || current == null) return;
    final queueIndex = _consumedCount() + index;
    if (queueIndex < 0 || queueIndex >= _queue.length) return;
    final sequenceIndex = start + queueIndex;
    _queue.removeAt(queueIndex);
    _activeSequence.removeAt(sequenceIndex);
    await player.removeAudioSourceAt(sequenceIndex);
    _queueEnd = _queueEnd! - 1;

    if (_queue.isEmpty) {
      await _replaceTailAfter(_anchorBaseIndex! + 1);
      _clearQueueState();
    } else {
      await _replaceResumeTail();
    }
    notifyListeners();
  }

  /// Queues [song] to play right after the current one.
  Future<void> playNext(Song song) async {
    final wasIdle = currentSong == null;
    await addToQueue(song);
    if (!wasIdle) await moveUpcoming(upcomingQueue.length - 1, 0);
  }

  /// Moves an upcoming queued song; indices are positions in [upcomingQueue].
  Future<void> moveUpcoming(int from, int to) async {
    final start = _queueStart;
    final upcoming = upcomingQueue.length;
    if (start == null || from == to) return;
    if (from < 0 || from >= upcoming || to < 0 || to >= upcoming) return;
    final consumed = _consumedCount();
    _queue.insert(consumed + to, _queue.removeAt(consumed + from));
    final fromSequence = start + consumed + from;
    final toSequence = start + consumed + to;
    _activeSequence.insert(toSequence, _activeSequence.removeAt(fromSequence));
    notifyListeners();
    await player.moveAudioSource(fromSequence, toSequence);
    // Strawberry mode resumes after the last queued song, which may have changed.
    await _replaceResumeTail();
    notifyListeners();
  }

  Future<void> setQueueMode(QueueMode mode) async {
    queueMode = mode;
    if (_queueStart != null && _queue.isNotEmpty) {
      await _replaceResumeTail();
    }
    notifyListeners();
  }

  Future<void> _replaceResumeTail() async {
    final anchor = _anchorBaseIndex;
    final end = _queueEnd;
    if (anchor == null || end == null || _queue.isEmpty) return;
    await _replaceTailAfter(_resumeIndex());
  }

  /// Where in [_order] playback continues once the queue is done.
  int _resumeIndex() => queueResumeIndex(
    mode: queueMode,
    anchorIndex: _anchorBaseIndex!,
    lastQueuedIndex: _order.indexWhere((song) => song.id == _queue.last.id),
  );

  Future<void> _replaceTailAfter(int baseIndex, {int? from}) async {
    final tailStart = from ?? (_queueEnd ?? player.currentIndex ?? -1) + 1;
    if (_activeSequence.length > tailStart) {
      _activeSequence.removeRange(tailStart, _activeSequence.length);
      await player.removeAudioSourceRange(
        tailStart,
        player.audioSources.length,
      );
    }
    if (baseIndex < _order.length) {
      final tail = _orderSlice(baseIndex, baseIndex);
      _activeSequence.addAll(tail);
      await player.addAudioSources(tail.map(_source).toList(growable: false));
    }
  }

  /// [_order] from [from] through [last] plus a window after it, marking
  /// the end as loaded.
  List<Song> _orderSlice(int from, int last) {
    final window = _window;
    _loadedEnd = window == null
        ? _order.length
        : math.min(_order.length, last + 1 + window);
    return _order.sublist(from.clamp(0, _loadedEnd), _loadedEnd);
  }

  /// Drops [_order] songs more than a window before [index], so the player
  /// is not handed them; returns [index]'s new position.
  // shortcut: previous and repeat-all reach back at most a window from where
  // playback started, keep an offset into the full list if that matters.
  int _rebase(int index) {
    final window = _window;
    if (window == null || index <= window) return index;
    _order = _order.sublist(index - window);
    return window;
  }

  /// Adds the next window of [_order] once playback nears the loaded end.
  Future<void> _loadMore() async {
    final more = _orderSlice(_loadedEnd, _loadedEnd - 1);
    _activeSequence.addAll(more);
    await player.addAudioSources(more.map(_source).toList(growable: false));
    notifyListeners();
  }

  /// Swaps in [value]'s copies of loaded songs whose tags were edited, so
  /// Now Playing, the notification and songs still to come show them.
  Future<void> _refreshTags(List<Song> value) async {
    final byId = {for (final song in value) song.id: song};
    Song fresh(Song song) => byId[song.id] ?? song;
    bool edited(Song song) => switch (byId[song.id]) {
      final newer? =>
        newer.title != song.title ||
            newer.artist != song.artist ||
            newer.album != song.album,
      null => false,
    };
    _order = [for (final song in _order) fresh(song)];
    _queue.setAll(0, _queue.map(fresh).toList());
    _restoredQueue = [for (final song in _restoredQueue) fresh(song)];
    final changed = [
      for (final (i, song) in _activeSequence.indexed)
        if (edited(song)) i,
    ];
    if (changed.isEmpty) return;
    final current = player.currentIndex;
    _rearranging = currentSong == null ? null : fresh(currentSong!);
    try {
      for (final i in changed) {
        final song = _activeSequence[i] = fresh(_activeSequence[i]);
        if (i == current) {
          // Play the new copy from the same spot, then drop the old one.
          await player.insertAudioSource(i + 1, _source(song));
          await player.seek(player.position, index: i + 1);
          // just_audio_background sends the notification its new song only
          // once the index has held for 100 ms; back at i sooner, it sees no
          // change.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await player.removeAudioSourceAt(i);
        } else {
          await player.removeAudioSourceAt(i);
          await player.insertAudioSource(i, _source(song));
        }
      }
    } finally {
      _rearranging = null;
    }
  }

  AudioSource _source(Song song) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final cover = android ? MusicLibrary.coverUri(song) : null;
    return AudioSource.uri(
      song.uri,
      tag: MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
        // A saved cover, else the song's own art through MediaStore.
        artUri: cover ?? (android ? song.uri : null),
        // A string: audio_service reads this key with getString.
        extras: cover == null && android ? {'loadThumbnailUri': 'true'} : null,
      ),
    );
  }

  /// Starts a new listening session when the playing song changes (or on
  /// [restart]), logging the previous one.
  void _trackListening({bool restart = false}) {
    final song = currentSong;
    if (!restart && song?.id == _listenSong?.id) return;
    _endListening();
    if (song != null) {
      _listenSong = song;
      _listenStart = DateTime.now();
    }
    _syncListenClock();
  }

  /// The clock runs only while audio is actually playing.
  void _syncListenClock() {
    final audible =
        player.playing && player.processingState == ProcessingState.ready;
    if (audible && _listenSong != null) {
      _listenClock.start();
    } else {
      _listenClock.stop();
    }
  }

  /// The session in progress (not yet in the log), so stats include it.
  PlayRecord? get currentListen => _currentListen;

  PlayRecord? get _currentListen {
    final song = _listenSong;
    final ms = _listenClock.elapsedMilliseconds;
    if (song == null || ms < 1000) return null;
    return PlayRecord.of(song, _listenStart!, ms);
  }

  void _savePendingListen() {
    if (_currentListen case final record?) {
      unawaited(_history.savePending(record));
    }
  }

  void _endListening() {
    final record = _currentListen;
    _listenClock
      ..stop()
      ..reset();
    _listenSong = null;
    if (record != null) unawaited(_history.append(record));
    unawaited(_history.savePending(null));
  }

  /// Pushes the playing song to the home-screen widgets when it changes.
  void _syncWidget() {
    final song = currentSong;
    if (song == null) return;
    final state = '${song.id}/${player.playing}';
    if (state == _widgetState) return;
    _widgetState = state;
    _channel
        .invokeMethod<void>('updateWidget', {
          'id': song.id,
          'title': song.title,
          'artist': song.artist,
          'uri': song.uri.toString(),
          'fileName': song.fileName,
          'playing': player.playing,
        })
        .catchError((Object _) {});
  }

  void _onIndexChanged(int? index) {
    _trackListening();
    if (_rearranging == null &&
        index != null &&
        index >= _activeSequence.length - 3 &&
        _loadedEnd < _order.length) {
      unawaited(_loadMore());
    }
    final end = _queueEnd;
    if (_rearranging == null && index != null && end != null && index > end) {
      _clearQueueState();
    }
    notifyListeners();
  }

  void _clearQueueState() {
    _queue.clear();
    _queueStart = null;
    _queueEnd = null;
    _anchorBaseIndex = null;
  }

  Future<void> togglePlay() async {
    if (player.playing) {
      await player.pause();
    } else if (currentSong == null && songs.isNotEmpty) {
      await playAt(0);
    } else {
      await player.play();
    }
  }

  Future<void> next() async {
    if (player.hasNext) await player.seekToNext();
  }

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
    } else if (player.hasPrevious) {
      await player.seekToPrevious();
    }
  }

  /// Reorders everything around the playing song without interrupting it;
  /// queued songs still play next.
  Future<void> toggleShuffle() async {
    shuffleEnabled = !shuffleEnabled;
    final current = currentSong;
    final index = player.currentIndex;
    if (current == null || index == null) {
      notifyListeners();
      return;
    }
    final consumed = _consumedCount();
    // While a queued song plays, the list song that started the queue
    // stays the point the list continues from.
    final anchorSong = consumed > 0 && _anchorBaseIndex! >= 0
        ? _order[_anchorBaseIndex!]
        : current;
    _order = shuffleEnabled ? _shuffled(songs, first: anchorSong) : songs;
    final anchor = _rebase(
      _order.indexWhere((song) => song.id == anchorSong.id),
    );
    final before = [
      ..._order.take(consumed > 0 ? anchor + 1 : math.max(anchor, 0)),
      ..._queue.take(math.max(consumed - 1, 0)),
    ];
    if (_queueStart != null) {
      _anchorBaseIndex = anchor;
      _queueStart = anchor + 1;
      _queueEnd = anchor + _queue.length;
    }
    _rearranging = current;
    _activeSequence
      ..removeRange(0, index)
      ..insertAll(0, before);
    try {
      if (index > 0) await player.removeAudioSourceRange(0, index);
      if (before.isNotEmpty) {
        await player.insertAudioSources(
          0,
          before.map(_source).toList(growable: false),
        );
      }
      await _replaceTailAfter(
        _queueStart != null ? _resumeIndex() : anchor + 1,
        // The player may not report the shifted current index yet.
        from: (_queueEnd ?? before.length) + 1,
      );
    } finally {
      _rearranging = null;
    }
    _baseSequence =
        _queueStart == null && !shuffleEnabled && identical(_order, songs);
    notifyListeners();
  }

  /// [list] in random order, starting with [first].
  static List<Song> _shuffled(List<Song> list, {required Song first}) => [
    first,
    ...([...list]
      ..remove(first)
      ..shuffle()),
  ];

  /// Songs queued in the last session; they play after the next song started.
  void restoreQueue(List<Song> queued) {
    if (_hasSelection || queued.isEmpty) return;
    _restoredQueue = queued;
    notifyListeners();
  }

  bool get sleepTimerOn => _sleepTicker != null;

  /// Time left before the sleep timer pauses playback.
  Duration? get sleepRemaining {
    if (_sleepAfterSong) {
      final duration = player.duration;
      return duration == null ? null : duration - player.position;
    }
    return _sleepAt?.difference(DateTime.now());
  }

  /// Pauses after [after], or at the end of the playing song when null.
  void setSleepTimer(Duration? after) {
    _sleepTicker?.cancel();
    _sleepAt = after == null ? null : DateTime.now().add(after);
    _sleepAfterSong = after == null;
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = sleepRemaining;
      // The list ran out first: nothing left to pause.
      if (player.processingState == ProcessingState.completed) {
        cancelSleepTimer();
        return;
      }
      if (left == null) return;
      if (!_sleepAfterSong && left <= Duration.zero) {
        unawaited(_sleepNow());
        return;
      }
      // Fades out over the last seconds; quiet while paused is harmless.
      final volume = left < _sleepFade
          ? left.inMilliseconds / _sleepFade.inMilliseconds
          : 1.0;
      unawaited(player.setVolume(volume.clamp(0.0, 1.0)));
      notifyListeners();
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepAt = null;
    _sleepAfterSong = false;
    unawaited(player.setVolume(1));
    notifyListeners();
  }

  Future<void> _sleepNow() async {
    await player.pause();
    // After pausing, so the volume coming back is not heard.
    cancelSleepTimer();
  }

  Future<void> cycleLoopMode() async {
    final next = switch (player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await player.setLoopMode(next);
  }

  @override
  void dispose() {
    _checkpoint.cancel();
    _sleepTicker?.cancel();
    _endListening();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    player.dispose();
    super.dispose();
  }
}

/// Keeps the player's shuffle order the same as its play order. Cars and
/// Bluetooth devices can turn on the player's own shuffle through the media
/// session, bypassing [PlayerController.toggleShuffle]; with this order that
/// changes nothing, so the queue and up next stay right.
class _InOrder extends ShuffleOrder {
  @override
  final List<int> indices = [];

  @override
  void shuffle({int? initialIndex}) {}

  @override
  void insert(int index, int count) => _reset(indices.length + count);

  @override
  void removeRange(int start, int end) =>
      _reset(indices.length - (end - start));

  @override
  void clear() => indices.clear();

  void _reset(int length) => indices
    ..clear()
    ..addAll(List.generate(length, (i) => i));
}
