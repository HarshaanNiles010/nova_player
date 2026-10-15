import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'listening_history.dart';
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

  final AudioPlayer player = AudioPlayer();
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
  bool _restoreShuffle = false;

  Song? get currentSong {
    if (!_hasSelection) return null;
    final index = player.currentIndex;
    return index == null || index < 0 || index >= _activeSequence.length
        ? null
        : _activeSequence[index];
  }

  List<Song> get upcomingQueue {
    if (_queueStart == null || _queue.isEmpty) return const [];
    return List.unmodifiable(_queue.skip(_consumedCount()));
  }

  /// Sequence indices that play after the current song, in play order
  /// (shuffled when shuffle is on). Queued songs come first.
  List<int> get _upNextIndices {
    final current = player.currentIndex;
    if (currentSong == null || current == null) return const [];
    final order = player.effectiveIndices;
    final at = order.indexOf(current);
    return at < 0 ? const [] : order.sublist(at + 1);
  }

  /// Everything that will play after the current song, queued songs first.
  List<Song> get upNext => [
    for (final index in _upNextIndices) _activeSequence[index],
  ];

  /// Jumps straight to [upNext]`[index]`.
  Future<void> playUpNext(int index) async {
    final indices = _upNextIndices;
    if (index < 0 || index >= indices.length) return;
    await player.seek(Duration.zero, index: indices[index]);
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
      notifyListeners();
      return;
    }
    _activeSequence
      ..clear()
      ..addAll(value);
    await player.setAudioSources(
      value.map(_source).toList(growable: false),
      preload: false,
    );
    notifyListeners();
  }

  /// Plays [baseIndex] of [order] (default: current [songs]); a new order
  /// becomes the base sequence so next/previous follow what the user sees.
  Future<void> playAt(int baseIndex, {List<Song>? order}) async {
    if (order != null && !identical(order, songs)) {
      songs = order;
      _baseSequence = false;
    }
    // An idle player drops seek(index:), so the first play would start at track 0.
    if (!_baseSequence || player.processingState == ProcessingState.idle) {
      _activeSequence
        ..clear()
        ..addAll(songs);
      await player.setAudioSources(
        songs.map(_source).toList(growable: false),
        initialIndex: baseIndex,
      );
      _baseSequence = true;
    } else {
      await player.seek(Duration.zero, index: baseIndex);
    }
    _clearQueueState();
    _hasSelection = true;
    _trackListening();
    notifyListeners();
    // just_audio's play future completes only after playback pauses or ends.
    unawaited(player.play());
  }

  Future<void> addToQueue(Song song) async {
    if (currentSong == null) {
      await playAt(songs.indexOf(song));
      return;
    }
    if (_queueStart == null) {
      _anchorBaseIndex = songs.indexWhere(
        (candidate) => candidate.id == currentSong!.id,
      );
      _queueStart = player.currentIndex! + 1;
      _queueEnd = _queueStart! - 1;
      if (player.shuffleModeEnabled) {
        // shortcut: queues temporarily play linearly, use a custom ShuffleOrder
        // if interleaving queued and shuffled tracks becomes a priority.
        _restoreShuffle = true;
        await player.setShuffleModeEnabled(false);
      }
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
    final lastQueuedIndex = songs.indexWhere(
      (song) => song.id == _queue.last.id,
    );
    final resumeIndex = queueResumeIndex(
      mode: queueMode,
      anchorIndex: anchor,
      lastQueuedIndex: lastQueuedIndex,
    );
    await _replaceTailAfter(resumeIndex);
  }

  Future<void> _replaceTailAfter(int baseIndex) async {
    final tailStart = (_queueEnd ?? player.currentIndex ?? -1) + 1;
    if (_activeSequence.length > tailStart) {
      _activeSequence.removeRange(tailStart, _activeSequence.length);
      await player.removeAudioSourceRange(
        tailStart,
        player.audioSources.length,
      );
    }
    if (baseIndex < songs.length) {
      final tail = songs.sublist(baseIndex.clamp(0, songs.length));
      _activeSequence.addAll(tail);
      await player.addAudioSources(tail.map(_source).toList(growable: false));
    }
  }

  AudioSource _source(Song song) {
    return AudioSource.uri(
      song.uri,
      tag: MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
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
          'playing': player.playing,
        })
        .catchError((Object _) {});
  }

  void _onIndexChanged(int? index) {
    _trackListening();
    final end = _queueEnd;
    if (index != null && end != null && index > end) {
      _clearQueueState();
      if (_restoreShuffle) {
        _restoreShuffle = false;
        unawaited(player.setShuffleModeEnabled(true));
      }
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

  Future<void> toggleShuffle() async {
    final enabled = !player.shuffleModeEnabled;
    if (enabled) await player.shuffle();
    await player.setShuffleModeEnabled(enabled);
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
    _endListening();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    player.dispose();
    super.dispose();
  }
}
