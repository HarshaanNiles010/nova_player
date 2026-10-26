import 'dart:async';
import 'dart:io' show HttpException;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'package:flutter/rendering.dart';

import 'backup.dart';
import 'downloads.dart';
import 'duplicates.dart';
import 'duplicates_page.dart';
import 'equalizer_page.dart';
import 'group_by.dart';
import 'listening_history.dart';
import 'lyrics.dart';
import 'lyrics_translation.dart';
import 'm3u.dart';
import 'music_library.dart';
import 'player_controller.dart';
import 'playlists.dart';
import 'queue_mode.dart';
import 'rule_playlist_editor.dart';
import 'rule_playlists.dart';
import 'settings_store.dart';
import 'smart_playlists.dart';
import 'song.dart';
import 'stats_page.dart';
import 'theme.dart';
import 'translation_models_page.dart';
import 'waveform.dart';

class MusicHomePage extends StatefulWidget {
  const MusicHomePage({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage>
    with _SongSelection<MusicHomePage> {
  final _library = MusicLibrary();
  final _player = PlayerController();
  final _settings = SettingsStore();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  List<Song> _songs = const [];

  /// Every song found, including ones hidden from [_songs].
  List<Song> _allSongs = const [];
  Set<String> _hidden = {};
  bool _loading = true;
  String? _error;
  String _query = '';
  GroupBy _groupBy = GroupBy.none;

  Map<String, List<Song>> _groupsOf(List<Song> songs) =>
      groupSongs(songs, _groupBy.keyFor);

  /// Playback order matching the list on screen; cached so playAt keeps the
  /// same instance and does not reload the player on every tap.
  List<Song> _playOrder = const [];

  @override
  List<Song> get selectableSongs => _rows.whereType<Song>().toList();

  @override
  PlayerController get selectionPlayer => _player;

  void _updatePlayOrder() {
    _playOrder = _groupBy == GroupBy.none
        ? _songs
        : [for (final group in _groupsOf(_songs).values) ...group];
  }

  /// Songs, with a group-name String before each group when grouped.
  List<Object> get _rows {
    final songs = _visibleSongs;
    if (_groupBy == GroupBy.none) return songs;
    return [
      for (final entry in _groupsOf(songs).entries) ...[
        entry.key,
        ...entry.value,
      ],
    ];
  }

  Future<void> _selectGroupBy(GroupBy group) async {
    setState(() {
      _groupBy = group;
      _updatePlayOrder();
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _settings.saveGroupBy(group);
  }

  List<Song> get _visibleSongs {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _songs;
    return _songs
        .where(
          (song) => '${song.title} ${song.artist} ${song.album}'
              .toLowerCase()
              .contains(query),
        )
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    MusicLibrary.libraryChanged.addListener(_reloadSongs);
    _initialize();
  }

  /// Reads the library again without the loading spinner, keeping the scroll.
  Future<void> _reloadSongs() async {
    try {
      _allSongs = await _library.loadSongs();
      await _showSongs();
    } catch (_) {
      _showMessage('The music library could not be read.');
    }
  }

  Future<void> _initialize() async {
    // Before anything plays: a newer checkpoint would overwrite the leftover one.
    await ListeningHistory.instance.recoverPending();
    await _player.setQueueMode(await _settings.loadQueueMode());
    _groupBy = await _settings.loadGroupBy();
    _hidden = await _settings.loadHidden();
    unawaited(restoreEqualizer(_player.equalizer));
    await _loadLibrary();
    await _restoreSession();
  }

  /// Brings back the queue, shuffle and the paused song from the last
  /// session, then keeps them saved.
  Future<void> _restoreSession() async {
    // Without a library nothing can be matched, and saving would wipe it.
    if (_songs.isEmpty) return;
    final byId = {for (final song in _songs) song.id: song};
    _player.shuffleEnabled = await _settings.loadShuffle();
    _player.restoreQueue([
      for (final id in await _settings.loadQueue()) ?byId[id],
    ]);
    final (id, position) = await _settings.loadNowPlaying();
    // shortcut: resumes within the whole library, not the album or playlist
    // it was played from; save that list too if it matters.
    if (byId[id] case final song?) {
      try {
        await _player.playAt(
          _playOrder.indexOf(song),
          order: _playOrder,
          position: position,
          autoplay: false,
        );
      } catch (_) {
        // The file may be gone or unreadable; start fresh instead.
      }
    }
    _player.addListener(_saveSession);
    _positionSaver = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_player.player.playing) _savePosition();
    });
  }

  String? _savedQueue;
  String? _savedState;
  Timer? _positionSaver;

  void _saveSession() {
    final ids = [for (final song in _player.upcomingQueue) song.id];
    final key = ids.join('\n');
    if (key != _savedQueue) {
      _savedQueue = key;
      _settings.saveQueue(ids);
    }
    final state =
        '${_player.currentSong?.id}/${_player.player.playing}/'
        '${_player.shuffleEnabled}';
    if (state == _savedState) return;
    _savedState = state;
    _settings.saveShuffle(_player.shuffleEnabled);
    _savePosition();
  }

  void _savePosition() {
    if (_player.currentSong case final song?) {
      _settings.saveNowPlaying(song.id, _player.player.position);
    }
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _allSongs = await _library.loadSongs();
      final songs = _shownSongs();
      await _player.setSongs(songs);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _updatePlayOrder();
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.code == 'PERMISSION_DENIED'
            ? 'Nova Player needs audio access to find music on your phone and memory card.'
            : 'The music library could not be read.';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The music library could not be read.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Song> _shownSongs() => _hidden.isEmpty
      ? _allSongs
      : [
          for (final song in _allSongs)
            if (!_hidden.contains(song.uri.toString())) song,
        ];

  Future<void> _setHidden(List<Song> copies, bool hidden) async {
    final uris = copies.map((song) => song.uri.toString());
    hidden ? _hidden.addAll(uris) : _hidden.removeAll(uris);
    await _settings.saveHidden(_hidden);
    await _showSongs();
  }

  Future<void> _showSongs() async {
    final songs = _shownSongs();
    await _player.setSongs(songs);
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _updatePlayOrder();
    });
  }

  void _openDuplicates() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DuplicatesPage(
          groups: findDuplicates(_allSongs),
          isHidden: (song) => _hidden.contains(song.uri.toString()),
          onHide: _setHidden,
        ),
      ),
    );
  }

  Future<void> _play(Song song) async {
    try {
      await _player.playAt(_playOrder.indexOf(song), order: _playOrder);
      if (mounted) _openNowPlaying();
    } on PlayerException catch (error) {
      _showMessage('Could not play ${song.format}: ${error.message}');
    } catch (_) {
      _showMessage('This audio file could not be played.');
    }
  }

  Future<void> _addToQueue(Song song) async {
    final wasIdle = _player.currentSong == null;
    try {
      await _player.addToQueue(song);
      _showMessage(
        wasIdle ? 'Playing ${song.title}' : 'Added ${song.title} to queue',
      );
    } catch (_) {
      _showMessage('Could not update the queue.');
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          initialMode: _player.queueMode,
          themeController: widget.themeController,
          onModeChanged: (mode) async {
            await _settings.saveQueueMode(mode);
            await _player.setQueueMode(mode);
          },
          onReload: _loadLibrary,
          onFindDuplicates: _openDuplicates,
          equalizer: _player.equalizer,
          songCount: () => _songs.length,
        ),
      ),
    );
  }

  void _openLibraryPage(Widget page) {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => page)),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openNowPlaying() {
    if (_player.currentSong == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NowPlayingPage(controller: _player),
      ),
    );
  }

  @override
  void dispose() {
    MusicLibrary.libraryChanged.removeListener(_reloadSongs);
    _positionSaver?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return selectionScope(_buildScaffold());
  }

  Widget _buildScaffold() {
    return Scaffold(
      key: _scaffoldKey,
      drawer: NovaDrawer(
        onTracks: () => Navigator.pop(context),
        onAlbums: () =>
            _openLibraryPage(AlbumsPage(songs: _songs, player: _player)),
        onArtists: () =>
            _openLibraryPage(ArtistsPage(songs: _songs, player: _player)),
        onFolders: () =>
            _openLibraryPage(FoldersPage(songs: _songs, player: _player)),
        onPlaylists: () => _openLibraryPage(PlaylistsPage(player: _player)),
        onSmartPlaylists: () =>
            _openLibraryPage(SmartPlaylistsPage(player: _player)),
        onStats: () =>
            _openLibraryPage(StatsPage(player: _player, library: _songs)),
        onQueue: () {
          Navigator.pop(context);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => showQueueSheet(context, _player),
          );
        },
        onSettings: () {
          Navigator.pop(context);
          WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings());
        },
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _FastScroller(
                    controller: _scrollController,
                    labelAt: (fraction) {
                      final rows = _rows;
                      if (rows.isEmpty) return null;
                      final row = rows[(fraction * (rows.length - 1)).round()];
                      return switch (row) {
                        final String group => group,
                        final Song song when _groupBy != GroupBy.none =>
                          _groupBy.keyFor(song),
                        final Song song => song.indexLetter,
                        _ => null,
                      };
                    },
                    child: RefreshIndicator(
                      onRefresh: _loadLibrary,
                      child: CustomScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                            sliver: SliverToBoxAdapter(
                              child: _Header(
                                songCount: _songs.length,
                                onMenu: () =>
                                    _scaffoldKey.currentState?.openDrawer(),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
                            sliver: SliverToBoxAdapter(
                              child: TextField(
                                controller: _searchController,
                                onChanged: (value) =>
                                    setState(() => _query = value),
                                decoration: const InputDecoration(
                                  hintText: 'Search songs, artists, albums',
                                  prefixIcon: Icon(Icons.search_rounded),
                                  filled: false,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.zero,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            sliver: SliverToBoxAdapter(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: PopupMenuButton<GroupBy>(
                                  tooltip: 'Group by',
                                  initialValue: _groupBy,
                                  onSelected: _selectGroupBy,
                                  itemBuilder: (context) => [
                                    for (final group in GroupBy.values)
                                      CheckedPopupMenuItem(
                                        value: group,
                                        checked: group == _groupBy,
                                        child: Text(group.label),
                                      ),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.segment_rounded,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text('Group by: ${_groupBy.label}'),
                                        const Icon(
                                          Icons.arrow_drop_down_rounded,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          ..._buildLibrarySlivers(),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 112),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Left of the scroll bar so the two never overlap.
                  Positioned(
                    right: 56,
                    bottom: 16,
                    child: _BackToTopButton(controller: _scrollController),
                  ),
                ],
              ),
            ),
            if (selecting)
              selectionBar()
            else
              AnimatedBuilder(
                animation: _player,
                builder: (context, _) => _player.currentSong == null
                    ? const SizedBox.shrink()
                    : MiniPlayer(controller: _player, onTap: _openNowPlaying),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildLibrarySlivers() {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _LibraryMessage(
            icon: Icons.library_music_rounded,
            title: 'Let Nova find your music',
            message: _error!,
            actionLabel: 'Try again',
            onAction: _loadLibrary,
          ),
        ),
      ];
    }
    if (_songs.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _LibraryMessage(
            icon: Icons.sd_storage_rounded,
            title: 'No music found',
            message: Theme.of(context).platform == TargetPlatform.iOS
                ? 'Copy audio files into Nova Player with Finder or the '
                      'Files app, then refresh.'
                : 'Add audio files to your phone or memory card, then refresh.',
            actionLabel: 'Refresh',
            onAction: _loadLibrary,
          ),
        ),
      ];
    }
    if (_visibleSongs.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _LibraryMessage(
            icon: Icons.search_off_rounded,
            title: 'No matches',
            message: 'Try a different title, artist, or album.',
          ),
        ),
      ];
    }
    final rows = _rows;
    final groupSizes = _groupBy == GroupBy.none
        ? const <String, int>{}
        : {
            for (final entry in _groupsOf(_visibleSongs).entries)
              entry.key: entry.value.length,
          };
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        // Fixed row height lets fast-scroll jumps skip straight to an offset;
        // a plain SliverList lays out every row in between, which hung the app.
        sliver: SliverPrototypeExtentList.builder(
          prototypeItem: SongTile(
            song: _visibleSongs.first,
            active: false,
            onTap: () {},
            onQueue: () {},
          ),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            if (row is String) {
              return Align(
                alignment: Alignment.bottomLeft,
                child: _GroupHeader(title: row, count: groupSizes[row] ?? 0),
              );
            }
            final song = row as Song;
            return SongTile(
              song: song,
              active: _player.currentSong?.id == song.id,
              selected: selecting ? selectedIds.contains(song.id) : null,
              onTap: () => selecting ? toggleSelected(song) : _play(song),
              onQueue: () => _addToQueue(song),
              onLongPress: () => toggleSelected(song),
              onActions: () =>
                  showSongActions(context, song: song, player: _player),
            );
          },
        ),
      ),
    ];
  }
}

/// Right-edge scroll bar with a fixed-size draggable thumb and a letter bubble.
class _FastScroller extends StatefulWidget {
  const _FastScroller({
    required this.controller,
    required this.labelAt,
    required this.child,
  });

  final ScrollController controller;
  final String? Function(double fraction) labelAt;
  final Widget child;

  @override
  State<_FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<_FastScroller> {
  static const _thumbHeight = 56.0;
  static const _touchWidth = 44.0;
  // Kept off the screen edge, where Android's back gesture steals touches.
  static const _barInset = 12.0;
  bool _dragging = false;

  void _dragBy(double dy, double travel) {
    final position = widget.controller.position;
    final offset = position.pixels + dy / travel * position.maxScrollExtent;
    widget.controller.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final travel = constraints.maxHeight - _thumbHeight;
        return Stack(
          children: [
            widget.child,
            Positioned.fill(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final controller = widget.controller;
                  if (travel <= 0 ||
                      !controller.hasClients ||
                      !controller.position.hasContentDimensions ||
                      controller.position.maxScrollExtent <= 0) {
                    return const SizedBox.shrink();
                  }
                  final fraction =
                      (controller.offset / controller.position.maxScrollExtent)
                          .clamp(0.0, 1.0);
                  final top = fraction * travel;
                  final label = _dragging ? widget.labelAt(fraction) : null;
                  return Stack(
                    children: [
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: _barInset + 2,
                        width: 2,
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: colors.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                      Positioned(
                        top: top,
                        right: 0,
                        width: _touchWidth,
                        height: _thumbHeight,
                        child: Semantics(
                          label: 'Fast scroll',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragStart: (_) =>
                                setState(() => _dragging = true),
                            onVerticalDragUpdate: (details) =>
                                _dragBy(details.delta.dy, travel),
                            onVerticalDragEnd: (_) =>
                                setState(() => _dragging = false),
                            onVerticalDragCancel: () =>
                                setState(() => _dragging = false),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                margin: const EdgeInsets.only(right: _barInset),
                                width: _dragging ? 8 : 6,
                                color: _dragging
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (label != null)
                        Positioned(
                          top: (top + _thumbHeight / 2 - 32).clamp(
                            0.0,
                            constraints.maxHeight - 64,
                          ),
                          right: _touchWidth + 8,
                          height: 64,
                          child: IgnorePointer(
                            child: Container(
                              alignment: Alignment.center,
                              constraints: BoxConstraints(
                                minWidth: 64,
                                maxWidth: constraints.maxWidth * 0.7,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              color: colors.primary,
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(color: colors.onPrimary),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Appears once the list is scrolled away from the top; taps scroll back up.
class _BackToTopButton extends StatelessWidget {
  const _BackToTopButton({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final visible = controller.hasClients && controller.offset > 800;
        return AnimatedScale(
          scale: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: FloatingActionButton.small(
            heroTag: 'back-to-top',
            tooltip: 'Back to top',
            onPressed: visible
                ? () => controller.animateTo(
                    0,
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutCubic,
                  )
                : null,
            child: const Icon(Icons.arrow_upward_rounded),
          ),
        );
      },
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 24, 40, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.songCount, required this.onMenu});

  final int songCount;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onMenu,
          tooltip: 'Open navigation',
          icon: const Icon(Icons.menu_rounded),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NOVA',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 5),
              ),
              const SizedBox(height: 4),
              Text(
                '$songCount LOCAL TRACKS',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.active,
    required this.onTap,
    required this.onQueue,
    this.onLongPress,
    this.onActions,
    this.selected,
  });

  final Song song;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onQueue;
  final VoidCallback? onLongPress;

  /// Adds "More" to the menu, for lists where long-press selects instead.
  final VoidCallback? onActions;

  /// Whether the song is ticked; null when the list is not selecting.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Swipe left to queue; returning false snaps the tile back into place.
    return Dismissible(
      key: ValueKey('queue-swipe-${song.id}'),
      direction: selected == null
          ? DismissDirection.endToStart
          : DismissDirection.none,
      dismissThresholds: const {DismissDirection.endToStart: 0.25},
      confirmDismiss: (_) async {
        HapticFeedback.mediumImpact();
        onQueue();
        return false;
      },
      background: ColoredBox(
        color: colors.primary,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Add to queue',
                  style: TextStyle(
                    color: colors.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.queue_music_rounded, color: colors.onPrimary),
              ],
            ),
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: ListTile(
          onTap: onTap,
          onLongPress: onLongPress,
          selected: selected ?? false,
          selectedTileColor: colors.primary.withValues(alpha: 0.12),
          minTileHeight: 72,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: selected == true
              ? SizedBox.square(
                  dimension: 44,
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: colors.primary,
                  ),
                )
              : NovaArtwork(song: song, size: 44),
          title: Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: active ? colors.primary : null,
            ),
          ),
          subtitle: Text(
            '${song.artist} / ${song.album}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    song.format,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.durationLabel,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
              PopupMenuButton<void>(
                tooltip: 'Song actions',
                // onTap, not onSelected: a void item's null value counts as a cancel.
                itemBuilder: (context) => [
                  PopupMenuItem<void>(
                    onTap: onQueue,
                    child: const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.queue_music_rounded),
                      title: Text('Add to queue'),
                    ),
                  ),
                  if (onActions != null)
                    PopupMenuItem<void>(
                      onTap: onActions,
                      child: const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.more_horiz_rounded),
                        title: Text('More'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NovaArtwork extends StatelessWidget {
  const NovaArtwork({super.key, required this.song, required this.size});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ExcludeSemantics(
      child: ValueListenableBuilder(
        valueListenable: MusicLibrary.artworkChanged,
        builder: (context, _, _) => FutureBuilder<Uint8List?>(
          future: MusicLibrary().loadThumbnail(song, pixels),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            return Container(
              width: size,
              height: size,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: bytes == null
                  ? Icon(
                      Icons.music_note_outlined,
                      color: colors.onSurfaceVariant,
                      size: size * 0.42,
                    )
                  : Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      cacheWidth: pixels,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller, required this.onTap});

  final PlayerController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final song = controller.currentSong!;
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<Duration>(
              stream: controller.player.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = controller.player.duration ?? song.duration;
                final progress = duration.inMilliseconds == 0
                    ? 0.0
                    : (position.inMilliseconds / duration.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      );
                return LinearProgressIndicator(value: progress, minHeight: 1);
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: controller.player.playing ? 'Pause' : 'Play',
                    onPressed: controller.togglePlay,
                    icon: Icon(
                      controller.player.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: controller.next,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    const monochrome = ColorScheme.dark(
      primary: Colors.white,
      onPrimary: Colors.black,
      secondary: Colors.white,
      onSecondary: Colors.black,
      surface: Colors.black,
      onSurface: Colors.white,
      surfaceContainer: Color(0xFF0D0D0D),
      surfaceContainerHigh: Color(0xFF171717),
      onSurfaceVariant: Color(0xFFAFAFAF),
      outline: Color(0xFF5C5C5C),
    );
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: monochrome,
        scaffoldBackgroundColor: Colors.black,
        fontFamily: 'JetBrainsMonoNF',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final song = controller.currentSong;
          if (song == null) return const SizedBox.shrink();
          final screen = MediaQuery.sizeOf(context);
          // Landscape: artwork and controls on the left, lyrics on the right.
          final wide = screen.width > screen.height;
          final playerSection = <Widget>[
            Row(
              children: [
                Expanded(
                  child: Text(
                    song.title,
                    maxLines: wide ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                _FavouriteButton(song: song),
              ],
            ),
            const SizedBox(height: 8),
            DefaultTextStyle.merge(
              style: const TextStyle(color: Color(0xFFAFAFAF)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: Row(
                children: [
                  Flexible(
                    child: InkWell(
                      onTap: () => openSongsWhere(
                        context,
                        controller,
                        song.artist,
                        (other) => other.artist == song.artist,
                      ),
                      child: Text(song.artist),
                    ),
                  ),
                  const Text('  /  '),
                  Flexible(
                    child: InkWell(
                      onTap: () => openSongsWhere(
                        context,
                        controller,
                        song.album,
                        song.sameAlbum,
                      ),
                      child: Text(song.album),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: wide ? 8 : 26),
            _WaveformSeekBar(
              controller: controller,
              song: song,
              height: wide ? 36 : 72,
            ),
            SizedBox(height: wide ? 4 : 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip: 'Shuffle',
                  color: controller.shuffleEnabled
                      ? Colors.white
                      : Colors.white54,
                  onPressed: controller.toggleShuffle,
                  icon: const Icon(Icons.shuffle_rounded),
                ),
                IconButton(
                  tooltip: 'Previous',
                  onPressed: controller.previous,
                  iconSize: 34,
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                IconButton.filled(
                  tooltip: controller.player.playing ? 'Pause' : 'Play',
                  onPressed: controller.togglePlay,
                  padding: EdgeInsets.all(wide ? 10 : 18),
                  iconSize: 38,
                  icon: Icon(
                    controller.player.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                IconButton(
                  tooltip: 'Next',
                  onPressed: controller.next,
                  iconSize: 34,
                  icon: const Icon(Icons.skip_next_rounded),
                ),
                IconButton(
                  tooltip: 'Repeat',
                  color: controller.player.loopMode != LoopMode.off
                      ? Colors.white
                      : Colors.white54,
                  onPressed: controller.cycleLoopMode,
                  icon: Icon(
                    controller.player.loopMode == LoopMode.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                  ),
                ),
              ],
            ),
          ];
          return Scaffold(
            appBar: AppBar(
              title: const Text(
                'NOW PLAYING',
                style: TextStyle(fontSize: 12, letterSpacing: 2.4),
              ),
              centerTitle: true,
              actions: [
                if (controller.sleepRemaining case final left?
                    when controller.sleepTimerOn)
                  TextButton.icon(
                    onPressed: () => _showSleepSheet(context, controller),
                    icon: const Icon(Icons.bedtime_rounded, size: 18),
                    label: Text(_clockLabel(left)),
                  )
                else
                  IconButton(
                    tooltip: 'Sleep timer',
                    onPressed: () => _showSleepSheet(context, controller),
                    icon: const Icon(Icons.bedtime_outlined),
                  ),
                IconButton(
                  tooltip: 'Queue',
                  onPressed: () => showQueueSheet(context, controller),
                  icon: Badge.count(
                    count: controller.upcomingQueue.length,
                    isLabelVisible: controller.upcomingQueue.isNotEmpty,
                    child: const Icon(Icons.queue_music_rounded),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The artwork takes whatever height the controls leave.
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
                            child: Column(
                              children: [
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, box) => Center(
                                      child: _DeviceArtwork(
                                        song: song,
                                        size: math.min(
                                          box.maxWidth,
                                          box.maxHeight,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ...playerSection,
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 12, 24, 20),
                            child: _LyricsPanel(
                              controller: controller,
                              song: song,
                            ),
                          ),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                      child: Column(
                        children: [
                          _DeviceArtwork(
                            song: song,
                            size: math.min(screen.width - 48, 380.0),
                          ),
                          const SizedBox(height: 30),
                          ...playerSection,
                          const SizedBox(height: 40),
                          _LyricsPanel(controller: controller, song: song),
                        ],
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}

/// Lyrics below the player controls; synced (LRC) lyrics follow playback.
class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel({required this.controller, required this.song});

  final PlayerController controller;
  final Song song;

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  final _headerKey = GlobalKey();
  late Future<List<LyricLine>> _lines;
  List<GlobalKey> _keys = const [];
  int _active = -1;
  bool _downloading = false;

  /// How much later than their timestamps the lines are shown; saved per song.
  Duration _offset = Duration.zero;

  void _shift(int milliseconds) {
    setState(() => _offset += Duration(milliseconds: milliseconds));
    SettingsStore().saveLyricsOffset(widget.song, _offset);
  }

  /// English under each line, while the translation is shown.
  List<String>? _english;
  bool _translating = false;

  /// Shows English under each line, or hides it again.
  Future<void> _translate(List<LyricLine> lines) async {
    if (_english != null) {
      setState(() => _english = null);
      return;
    }
    final song = widget.song;
    setState(() => _translating = true);
    List<String>? english;
    String? message;
    try {
      final library = MusicLibrary();
      // A saved translation first: no model work, nothing downloaded.
      final saved = await library.loadStoredTranslation(song);
      english = saved == null ? null : readTranslation(lines, saved);
      if (english == null) {
        final result = await translateLyrics(lines);
        english = result.english;
        if (english != null) {
          await library.saveTranslation(song, translationLrc(lines, english));
        }
        message = switch (result.reason) {
          NoTranslation.english => 'These lyrics are already in English.',
          NoTranslation.romanized =>
            'These lyrics are written in Latin letters (like romaji), which '
                'cannot be translated on the phone.',
          NoTranslation.unknownLanguage =>
            'Could not tell which language these lyrics are in.',
          null => null,
        };
      }
    } catch (_) {
      message =
          'Translation failed. The first time, each language needs internet '
          'to download (about 30 MB).';
    }
    if (!mounted) return;
    setState(() {
      _translating = false;
      if (widget.song.id == song.id) _english = english;
    });
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Looks the song up on LRCLIB and shows what it finds.
  Future<void> _download() async {
    final song = widget.song;
    setState(() => _downloading = true);
    String? message;
    try {
      final lyrics = await fetchLyrics(song);
      if (lyrics == null) {
        message = 'LRCLIB has no lyrics for this song.';
      } else {
        await MusicLibrary().saveDownloadedLyrics(song, lyrics);
      }
    } catch (_) {
      message = 'Could not reach LRCLIB. Check your connection.';
    }
    if (!mounted) return;
    setState(() {
      _downloading = false;
      if (message == null && widget.song.id == song.id) _load();
    });
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) _load();
  }

  void _load() {
    _active = -1;
    _english = null;
    late final Future<List<LyricLine>> lines;
    lines =
        (
          MusicLibrary().loadLyrics(widget.song),
          SettingsStore().loadLyricsOffset(widget.song),
        ).wait.then((loaded) {
          final (raw, offset) = loaded;
          final parsed = raw == null ? const <LyricLine>[] : parseLyrics(raw);
          // An older load finishing last (shuffle can switch songs and back) must
          // not replace the keys or offset of the lines on screen.
          if (identical(_lines, lines)) {
            _keys = List.generate(parsed.length, (_) => GlobalKey());
            _offset = offset;
          }
          return parsed;
        });
    _lines = lines;
  }

  /// Scrolls the page to keep the active line near the top third, but only once
  /// the user has scrolled down to the lyrics and is not touching the screen.
  void _reveal(int index) {
    final position = Scrollable.maybeOf(context)?.position;
    final line = _keys[index].currentContext?.findRenderObject();
    final header = _headerKey.currentContext?.findRenderObject();
    if (position == null || line == null || header == null) return;
    if (position.isScrollingNotifier.value) return;
    final viewport = RenderAbstractViewport.of(line);
    final lyricsTop = viewport.getOffsetToReveal(header, 0).offset;
    if (position.pixels < lyricsTop - position.viewportDimension / 2) return;
    final target = viewport.getOffsetToReveal(line, 0.3).offset;
    position.animateTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LyricLine>>(
      future: _lines,
      builder: (context, snapshot) {
        // FutureBuilder keeps the previous song's lines while the next loads.
        final lines = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (lines == null) return const SizedBox(height: 48);
        if (lines.isEmpty) {
          return Row(
            children: [
              const Expanded(
                child: Text(
                  'No lyrics found for this song',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _downloading ? null : _download,
                icon: _downloading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download lyrics'),
              ),
            ],
          );
        }
        final synced = lines.first.time != null;
        return StreamBuilder<Duration>(
          stream: synced
              ? widget.controller.player.positionStream
              : const Stream.empty(),
          builder: (context, position) {
            final active = synced
                ? activeLyricIndex(
                    lines,
                    (position.data ?? Duration.zero) - _offset,
                  )
                : -1;
            if (active != _active) {
              _active = active;
              if (active >= 0) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _reveal(active),
                );
              }
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'LYRICS',
                      key: _headerKey,
                      style: const TextStyle(fontSize: 12, letterSpacing: 2.4),
                    ),
                    const Spacer(),
                    if (synced) ...[
                      IconButton(
                        tooltip: 'Lyrics earlier',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _shift(-500),
                        icon: const Icon(Icons.remove_rounded, size: 18),
                      ),
                      Text(
                        '${_offset.isNegative ? '' : '+'}'
                        '${(_offset.inMilliseconds / 1000).toStringAsFixed(1)}s',
                        style: const TextStyle(fontSize: 12),
                      ),
                      IconButton(
                        tooltip: 'Lyrics later',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _shift(500),
                        icon: const Icon(Icons.add_rounded, size: 18),
                      ),
                    ],
                    TextButton.icon(
                      onPressed: _translating ? null : () => _translate(lines),
                      icon: _translating
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.translate_rounded, size: 18),
                      label: Text(
                        _translating
                            ? 'Translating...'
                            : _english == null
                            ? 'Translate'
                            : 'Original only',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < lines.length; i++)
                  InkWell(
                    key: _keys[i],
                    onTap: lines[i].time == null
                        ? null
                        : () => widget.controller.player.seek(
                            Duration(
                              milliseconds: math.max(
                                0,
                                (lines[i].time! + _offset).inMilliseconds,
                              ),
                            ),
                          ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 250),
                        style: TextStyle(
                          fontFamily: 'JetBrainsMonoNF',
                          fontSize: 20,
                          height: 1.35,
                          fontWeight: i == active
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: !synced || i == active
                              ? Colors.white
                              : i < active
                              ? Colors.white54
                              : Colors.white30,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(lines[i].text.isEmpty ? '♪' : lines[i].text),
                            if (_english?[i] case final english?
                                when english.isNotEmpty)
                              Text(
                                english,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w400,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                // Room for the last lines to scroll up to the reading position.
                SizedBox(height: MediaQuery.sizeOf(context).height * 0.35),
              ],
            );
          },
        );
      },
    );
  }
}

class _DeviceArtwork extends StatelessWidget {
  const _DeviceArtwork({required this.song, required this.size});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ValueListenableBuilder(
      valueListenable: MusicLibrary.artworkChanged,
      builder: (context, _, _) => FutureBuilder<Uint8List?>(
        // Sized thumbnail: MediaStore caches it, unlike the full embedded image.
        future: MusicLibrary().loadThumbnail(song, pixels),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          return Container(
            width: size,
            height: size,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: bytes == null
                ? Icon(
                    Icons.album_outlined,
                    color: colors.onSurfaceVariant,
                    size: size * 0.24,
                  )
                : Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: pixels,
                  ),
          );
        },
      ),
    );
  }
}

class _WaveformSeekBar extends StatelessWidget {
  const _WaveformSeekBar({
    required this.controller,
    required this.song,
    this.height = 72,
  });

  final PlayerController controller;
  final Song song;
  final double height;

  String _label(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: controller.player.positionStream,
      builder: (context, snapshot) {
        final duration = controller.player.duration ?? song.duration;
        final position = snapshot.data ?? Duration.zero;
        final max = math.max(1, duration.inMilliseconds).toDouble();
        final value = position.inMilliseconds.clamp(0, max.toInt()).toDouble();
        final progress = value / max;
        return Column(
          children: [
            SizedBox(
              height: height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WaveformPainter(
                        peaks: waveformPeaks(song.id, 72),
                        progress: progress,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        trackHeight: 0,
                        thumbColor: Colors.white,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 4,
                        ),
                        overlayColor: Colors.white12,
                      ),
                      child: Slider(
                        // No inset, so the dot spans the same width as the waveform bars.
                        padding: EdgeInsets.zero,
                        value: value,
                        max: max,
                        onChanged: (next) => controller.player.seek(
                          Duration(milliseconds: next.round()),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _label(position),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Text(
                  _label(duration),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.peaks, required this.progress});

  final List<double> peaks;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    // shortcut: shaped bars avoid decoding large FLAC files; decode cached peaks
    // when exact source-audio waveforms become worth the storage and CPU cost.
    final spacing = size.width / peaks.length;
    final activeBars = (peaks.length * progress).round();
    final paint = Paint()
      ..strokeWidth = math.max(1, spacing * 0.42)
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < peaks.length; index++) {
      paint.color = index < activeBars ? Colors.white : Colors.white24;
      final x = spacing * (index + 0.5);
      final height = peaks[index] * size.height;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.peaks != peaks;
}

class _LibraryMessage extends StatelessWidget {
  const _LibraryMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 54, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class NovaDrawer extends StatelessWidget {
  const NovaDrawer({
    super.key,
    required this.onTracks,
    required this.onAlbums,
    required this.onArtists,
    required this.onFolders,
    required this.onPlaylists,
    required this.onSmartPlaylists,
    required this.onStats,
    required this.onQueue,
    required this.onSettings,
  });

  final VoidCallback onTracks;
  final VoidCallback onAlbums;
  final VoidCallback onArtists;
  final VoidCallback onFolders;
  final VoidCallback onPlaylists;
  final VoidCallback onSmartPlaylists;
  final VoidCallback onStats;
  final VoidCallback onQueue;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NOVA',
                      style: TextStyle(fontSize: 22, letterSpacing: 5),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'LOCAL MUSIC PLAYER',
                      style: TextStyle(fontSize: 10, letterSpacing: 1.6),
                    ),
                  ],
                ),
              ),
            ),
            _DrawerItem(
              icon: Icons.music_note_rounded,
              label: 'My Tracks',
              onTap: onTracks,
            ),
            _DrawerItem(
              icon: Icons.album_rounded,
              label: 'Albums',
              onTap: onAlbums,
            ),
            _DrawerItem(
              icon: Icons.person_rounded,
              label: 'Artists',
              onTap: onArtists,
            ),
            _DrawerItem(
              icon: Icons.folder_rounded,
              label: 'Folders',
              onTap: onFolders,
            ),
            _DrawerItem(
              icon: Icons.library_music_rounded,
              label: 'My Playlists',
              onTap: onPlaylists,
            ),
            _DrawerItem(
              icon: Icons.auto_awesome_rounded,
              label: 'Smart Playlists',
              onTap: onSmartPlaylists,
            ),
            _DrawerItem(
              icon: Icons.queue_music_rounded,
              label: 'Queue',
              onTap: onQueue,
            ),
            _DrawerItem(
              icon: Icons.insights_rounded,
              label: 'Your Stats',
              onTap: onStats,
            ),
            const Spacer(),
            const Divider(height: 1),
            _DrawerItem(
              icon: Icons.settings_rounded,
              label: 'Settings',
              onTap: onSettings,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 54,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(icon, size: 21),
      title: Text(
        label.toUpperCase(),
        style: const TextStyle(fontSize: 12, letterSpacing: 1.2),
      ),
      onTap: onTap,
    );
  }
}

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key, required this.songs, required this.player});

  final List<Song> songs;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return _GroupedLibraryPage(
      title: 'Albums',
      groups: groupSongs(
        songs,
        (song) => '${song.album}\u0000${song.albumArtist}',
      ),
      player: player,
      name: (tracks) => tracks.first.album,
      detail: (tracks) => tracks.first.albumArtist,
    );
  }
}

class ArtistsPage extends StatelessWidget {
  const ArtistsPage({super.key, required this.songs, required this.player});

  final List<Song> songs;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return _GroupedLibraryPage(
      title: 'Artists',
      groups: groupSongs(songs, (song) => song.artist),
      player: player,
      detail: (tracks) {
        final albums = tracks
            .map((song) => (song.album, song.albumArtist))
            .toSet()
            .length;
        return '$albums ${albums == 1 ? 'album' : 'albums'}';
      },
    );
  }
}

/// Songs by the folder their file is in. Each folder lists only its own
/// files.
// shortcut: a flat list of folder paths, not a tree; nest them if libraries
// with deep folder structures need it.
class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key, required this.songs, required this.player});

  final List<Song> songs;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return _GroupedLibraryPage(
      title: 'Folders',
      groups: groupSongs(
        songs,
        (song) => song.folder.isEmpty ? 'Unknown folder' : song.folder,
      ),
      player: player,
      detail: (tracks) => _trackCount(tracks.length),
    );
  }
}

class _GroupedLibraryPage extends StatelessWidget {
  const _GroupedLibraryPage({
    required this.title,
    required this.groups,
    required this.player,
    required this.detail,
    this.name,
  });

  final String title;
  final Map<String, List<Song>> groups;
  final PlayerController player;
  final String Function(List<Song> tracks) detail;

  /// A group's name when it is not its key.
  final String Function(List<Song> tracks)? name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title.toUpperCase(),
          style: const TextStyle(fontSize: 14, letterSpacing: 2.4),
        ),
        actions: [
          IconButton(
            tooltip: 'Queue',
            onPressed: () => showQueueSheet(context, player),
            icon: const Icon(Icons.queue_music_rounded),
          ),
        ],
      ),
      body: groups.isEmpty
          ? Center(child: Text('No ${title.toLowerCase()} found.'))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              itemCount: groups.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 24,
                crossAxisSpacing: 18,
                childAspectRatio: 0.76,
              ),
              itemBuilder: (context, index) {
                final entry = groups.entries.elementAt(index);
                final tracks = entry.value;
                final label = name?.call(tracks) ?? entry.key;
                return InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SongCollectionPage(
                        title: label,
                        subtitle: _trackCount(tracks.length),
                        songs: tracks,
                        player: player,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Center(
                            child: _DeviceArtwork(
                              song: tracks.first,
                              size: math.min(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        detail(tracks).toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class SongCollectionPage extends StatefulWidget {
  const SongCollectionPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.songs,
    required this.player,
    this.playlist,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final List<Song> songs;
  final PlayerController player;

  /// Set when showing a playlist, so songs can be removed from it.
  final String? playlist;
  final List<Widget> actions;

  @override
  State<SongCollectionPage> createState() => _SongCollectionPageState();
}

class _SongCollectionPageState extends State<SongCollectionPage>
    with _SongSelection<SongCollectionPage> {
  @override
  String? get selectionPlaylist => widget.playlist;

  @override
  List<Song> get selectableSongs => _songs;

  @override
  PlayerController get selectionPlayer => widget.player;

  (List<Song>, List<Song>, List<Song>)? _cache;

  /// The page's songs as the library has them now: with edited tags, and
  /// without trashed files.
  List<Song> get _songs {
    final library = widget.player.library;
    if (_cache case (final songs, final from, final fresh)
        when identical(songs, widget.songs) && identical(from, library)) {
      return fresh;
    }
    final byId = {for (final song in library) song.id: song};
    final fresh = [for (final song in widget.songs) ?byId[song.id]];
    _cache = (widget.songs, library, fresh);
    return fresh;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) => selectionScope(_buildScaffold(_songs)),
    );
  }

  Widget _buildScaffold(List<Song> songs) {
    final playlist = widget.playlist;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, letterSpacing: 1.6),
        ),
        actions: widget.actions,
      ),
      bottomNavigationBar: selecting ? selectionBar() : null,
      body: songs.isEmpty
          ? const Center(child: Text('No songs left here.'))
          : playlist == null
          ? ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              itemCount: songs.length + 1,
              itemBuilder: (context, index) => index == 0
                  ? _header(context, songs)
                  : _tile(context, songs, index - 1),
            )
          // Drag handles, since long-press already selects.
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              header: _header(context, songs),
              buildDefaultDragHandles: false,
              itemCount: songs.length,
              onReorderItem: (from, to) {
                final ordered = [...songs];
                ordered.insert(to, ordered.removeAt(from));
                PlaylistStore.instance.reorder(playlist, ordered);
              },
              itemBuilder: (context, index) => Row(
                key: ValueKey(songs[index].id),
                children: [
                  Expanded(child: _tile(context, songs, index)),
                  ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.drag_handle_rounded),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _header(BuildContext context, List<Song> songs) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
    child: Row(
      children: [
        _DeviceArtwork(song: songs.first, size: 96),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            widget.subtitle.toUpperCase(),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _tile(BuildContext context, List<Song> songs, int index) {
    final song = songs[index];
    final player = widget.player;
    return SongTile(
      song: song,
      active: player.currentSong?.id == song.id,
      selected: selecting ? selectedIds.contains(song.id) : null,
      onTap: () async {
        if (selecting) return toggleSelected(song);
        // Next/previous follow this page's order, not the whole library.
        await player.playAt(index, order: songs);
        if (context.mounted) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NowPlayingPage(controller: player),
            ),
          );
        }
      },
      onQueue: () => player.addToQueue(song),
      onLongPress: () => toggleSelected(song),
      onActions: () => showSongActions(
        context,
        song: song,
        player: player,
        playlist: widget.playlist,
      ),
    );
  }
}

/// Heart that adds or removes the song from the Favourites playlist.
class _FavouriteButton extends StatelessWidget {
  const _FavouriteButton({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final store = PlaylistStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final liked = store.contains(PlaylistStore.favourites, song);
        return IconButton(
          tooltip: liked ? 'Remove from Favourites' : 'Add to Favourites',
          onPressed: () {
            HapticFeedback.lightImpact();
            liked
                ? store.remove(PlaylistStore.favourites, song)
                : store.add(PlaylistStore.favourites, song);
          },
          icon: Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: liked ? Theme.of(context).colorScheme.primary : null,
          ),
        );
      },
    );
  }
}

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key, required this.player});

  final PlayerController player;

  Future<void> _confirmDelete(BuildContext context, String name) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text('The songs stay on your phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (delete == true) await PlaylistStore.instance.delete(name);
  }

  void _say(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _export(
    BuildContext context,
    String name,
    List<Song> songs,
  ) async {
    try {
      final saved = await MusicLibrary().saveTextFile(
        '$name.m3u',
        'audio/x-mpegurl',
        toM3u(songs),
      );
      if (saved && context.mounted) _say(context, 'Saved $name.m3u');
    } catch (_) {
      if (context.mounted) _say(context, 'The playlist could not be saved.');
    }
  }

  Future<void> _import(BuildContext context) async {
    final String? text;
    try {
      text = await MusicLibrary().openTextFile();
    } catch (_) {
      if (context.mounted) _say(context, 'The file could not be read.');
      return;
    }
    if (text == null || !context.mounted) return;
    final songs = fromM3u(text, player.library);
    if (songs.isEmpty) {
      _say(context, 'None of the songs in that file are on this phone.');
      return;
    }
    final name = await _askPlaylistName(context, action: 'Import');
    if (name == null || name.isEmpty) return;
    await PlaylistStore.instance.replace(name, songs);
    if (context.mounted) {
      _say(context, 'Imported ${_trackCount(songs.length)} as $name');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = PlaylistStore.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Playlists'),
        actions: [
          IconButton(
            tooltip: 'Import .m3u playlist',
            onPressed: () => _import(context),
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final names = store.names;
          if (names.isEmpty) {
            return const _LibraryMessage(
              icon: Icons.library_music_rounded,
              title: 'No playlists yet',
              message:
                  'Long-press songs to select them, then tap Add to playlist.',
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final (name, songs) in [
                for (final name in names)
                  (name, store.songsOf(name, player.library)),
              ])
                ListTile(
                  leading: songs.isEmpty
                      ? const Icon(Icons.queue_music_rounded)
                      : NovaArtwork(song: songs.first, size: 48),
                  title: Text(name),
                  // Counts songs still on the phone, not every saved entry.
                  subtitle: Text(_trackCount(songs.length)),
                  trailing: IconButton(
                    tooltip: 'Delete playlist',
                    onPressed: () => _confirmDelete(context, name),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ListenableBuilder(
                        listenable: store,
                        builder: (context, _) {
                          final songs = store.songsOf(name, player.library);
                          if (songs.isEmpty) {
                            return Scaffold(
                              appBar: AppBar(title: Text(name)),
                              body: const _LibraryMessage(
                                icon: Icons.queue_music_rounded,
                                title: 'This playlist is empty',
                                message: 'Long-press songs to select them, then tap Add to playlist.',
                              ),
                            );
                          }
                          return SongCollectionPage(
                            title: name,
                            subtitle: _trackCount(songs.length),
                            songs: songs,
                            player: player,
                            playlist: name,
                            actions: [
                              IconButton(
                                tooltip: 'Export as .m3u',
                                onPressed: () => _export(context, name, songs),
                                icon: const Icon(Icons.ios_share_rounded),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class SmartPlaylistsPage extends StatelessWidget {
  const SmartPlaylistsPage({super.key, required this.player});

  final PlayerController player;

  void _open(
    BuildContext context,
    String title,
    List<Song> Function(List<PlayRecord> history) build,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          _SmartPlaylistPage(title: title, player: player, build: build),
    ),
  );

  Future<void> _pickGenre(BuildContext context) async {
    final genres = songsByGenre(player.library);
    final genre = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          children: [
            const ListTile(title: Text('Pick a genre')),
            if (genres.isEmpty)
              const ListTile(title: Text('No songs have genre tags.')),
            for (final MapEntry(key: name, value: songs) in genres.entries)
              ListTile(
                title: Text(name),
                trailing: Text(_trackCount(songs.length)),
                onTap: () => Navigator.pop(sheetContext, name),
              ),
          ],
        ),
      ),
    );
    if (genre == null || !context.mounted) return;
    _open(
      context,
      '$genre mix',
      (history) => genreMix(genres[genre]!, history, math.Random()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = player.library;
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Playlists')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: const Text('Recently played'),
            subtitle: const Text('Your last 50 songs'),
            onTap: () => _open(
              context,
              'Recently played',
              (history) => recentlyPlayed(history, library),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.new_releases_outlined),
            title: const Text('Newest songs'),
            subtitle: const Text('The 50 songs added to your phone last'),
            onTap: () =>
                _open(context, 'Newest songs', (_) => newestSongs(library)),
          ),
          ListTile(
            leading: const Icon(Icons.explore_outlined),
            title: const Text('Never played'),
            subtitle: const Text('50 random songs you have not heard yet'),
            onTap: () => _open(
              context,
              'Never played',
              (history) => neverPlayed(history, library, math.Random()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_rounded),
            title: const Text('Genre mix'),
            subtitle: const Text(
              '50 songs from a genre, the ones you will like most first',
            ),
            onTap: () => _pickGenre(context),
          ),
          const Divider(height: 32),
          ListenableBuilder(
            listenable: RulePlaylistStore.instance,
            builder: (context, _) => Column(
              children: [
                for (final playlist in RulePlaylistStore.instance.playlists)
                  ListTile(
                    leading: const Icon(Icons.rule_rounded),
                    title: Text(playlist.name),
                    subtitle: Text(
                      playlist.rules
                          .map(
                            (r) => '${r.field.label} ${r.op.label} ${r.value}',
                          )
                          .join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _open(
                      context,
                      playlist.name,
                      (history) =>
                          applyRules(playlist, library, history, math.Random()),
                    ),
                    trailing: PopupMenuButton<bool>(
                      onSelected: (edit) => edit
                          ? _edit(context, playlist)
                          : RulePlaylistStore.instance.delete(playlist.name),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: true, child: Text('Edit')),
                        PopupMenuItem(value: false, child: Text('Delete')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('New smart playlist'),
            subtitle: const Text('Pick songs with your own rules'),
            onTap: () => _edit(context, null),
          ),
        ],
      ),
    );
  }

  void _edit(BuildContext context, RulePlaylist? playlist) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RulePlaylistEditor(initial: playlist),
        ),
      );
}

/// A generated playlist: shuffle again, or save it to My Playlists.
class _SmartPlaylistPage extends StatefulWidget {
  const _SmartPlaylistPage({
    required this.title,
    required this.player,
    required this.build,
  });

  final String title;
  final PlayerController player;
  final List<Song> Function(List<PlayRecord> history) build;

  @override
  State<_SmartPlaylistPage> createState() => _SmartPlaylistPageState();
}

class _SmartPlaylistPageState extends State<_SmartPlaylistPage> {
  List<PlayRecord>? _history;
  List<Song> _songs = const [];

  @override
  void initState() {
    super.initState();
    ListeningHistory.instance.load().then((history) {
      if (!mounted) return;
      final current = widget.player.currentListen;
      _history = [...history, ?current];
      _generate();
    });
  }

  void _generate() => setState(() => _songs = widget.build(_history!));

  Future<void> _save() async {
    final name = await _askPlaylistName(
      context,
      initial: widget.title,
      action: 'Save',
    );
    if (name == null || name.isEmpty) return;
    await PlaylistStore.instance.replace(name, _songs);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Saved to My Playlists as $name')));
  }

  @override
  Widget build(BuildContext context) {
    if (_history == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_songs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const _LibraryMessage(
          icon: Icons.auto_awesome_rounded,
          title: 'No songs here yet',
          message: 'Listen to some music and come back.',
        ),
      );
    }
    return SongCollectionPage(
      title: widget.title,
      subtitle: _trackCount(_songs.length),
      songs: _songs,
      player: widget.player,
      actions: [
        IconButton(
          tooltip: 'Make a new one',
          onPressed: _generate,
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: 'Save as playlist',
          onPressed: _save,
          icon: const Icon(Icons.playlist_add_rounded),
        ),
      ],
    );
  }
}

String _trackCount(int count) => '$count ${count == 1 ? 'track' : 'tracks'}';

/// Long-press menu for a song: queue, playlists, and navigation.
/// Opens the library songs matching [match], e.g. one album or artist.
void openSongsWhere(
  BuildContext context,
  PlayerController player,
  String title,
  bool Function(Song other) match,
) {
  final songs = player.library.where(match).toList(growable: false);
  if (songs.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SongCollectionPage(
        title: title,
        subtitle: _trackCount(songs.length),
        songs: songs,
        player: player,
      ),
    ),
  );
}

Future<void> showSongActions(
  BuildContext context, {
  required Song song,
  required PlayerController player,
  String? playlist,
}) {
  HapticFeedback.mediumImpact();
  // Otherwise focus (and the keyboard) returns to the search box when sheets close.
  FocusManager.instance.primaryFocus?.unfocus();
  void notify(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      void run(Future<void> Function() action, String message) {
        Navigator.pop(sheetContext);
        action().then(
          (_) => notify(message),
          onError: (Object _) => notify('Could not update the queue.'),
        );
      }

      void open(String title, bool Function(Song other) match) {
        Navigator.pop(sheetContext);
        openSongsWhere(context, player, title, match);
      }

      final idle = player.currentSong == null;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: NovaArtwork(song: song, size: 48),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${song.artist} / ${song.album}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.playlist_play_rounded),
                title: const Text('Play next'),
                onTap: () => run(
                  () => player.playNext(song),
                  idle ? 'Playing ${song.title}' : 'Playing ${song.title} next',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('Add to queue'),
                onTap: () => run(
                  () => player.addToQueue(song),
                  idle
                      ? 'Playing ${song.title}'
                      : 'Added ${song.title} to queue',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  showAddToPlaylist(context, [song]);
                },
              ),
              if (playlist != null)
                ListTile(
                  leading: const Icon(Icons.playlist_remove_rounded),
                  title: Text('Remove from $playlist'),
                  onTap: () => run(
                    () => PlaylistStore.instance.remove(playlist, song),
                    'Removed ${song.title} from $playlist',
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit tags'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _editTags(
                    context,
                    [song],
                  ).then((message) => message == null ? null : notify(message));
                },
              ),
              ListTile(
                leading: const Icon(Icons.image_search_rounded),
                title: const Text('Download cover art'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _chooseCover(context, song, player.library, notify);
                },
              ),
              if (MusicLibrary.hasCover(song))
                ListTile(
                  leading: const Icon(Icons.hide_image_outlined),
                  title: const Text('Remove downloaded cover'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _removeCover(song, player.library).then(notify);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: const Text('Go to album'),
                subtitle: Text(song.album),
                onTap: () => open(song.album, song.sameAlbum),
              ),
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: const Text('Go to artist'),
                subtitle: Text(song.artist),
                onTap: () =>
                    open(song.artist, (other) => other.artist == song.artist),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Lets the user fix tags of [songs] in the app: the title of one song,
/// and the artist, album and album artist of one or many. Returns the
/// message to show, or null when nothing changed.
Future<String?> _editTags(BuildContext context, List<Song> songs) async {
  // Otherwise the search box takes focus (and the keyboard) back on close.
  FocusManager.instance.primaryFocus?.unfocus();
  final labels = {
    if (songs.length == 1) 'title': 'Title',
    'artist': 'Artist',
    'album': 'Album',
    'albumArtist': 'Album artist',
  };
  String tag(Song song, String key) => switch (key) {
    'title' => song.title,
    'artist' => song.artist,
    'album' => song.album,
    _ => song.albumArtist,
  };
  // The value every song has, or null when they differ.
  final shared = {
    for (final key in labels.keys)
      key: songs.every((song) => tag(song, key) == tag(songs.first, key))
          ? tag(songs.first, key)
          : null,
  };
  final fields = {
    for (final key in labels.keys)
      key: TextEditingController(text: shared[key] ?? ''),
  };
  final edited = songs.any(MusicLibrary.hasEditedTags);
  // A map saves, false resets to the files' tags, null cancels.
  final Object? answer = await showDialog<Object>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        songs.length == 1
            ? 'Edit tags'
            : 'Edit tags of ${_trackCount(songs.length)}',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final MapEntry(:key, :value) in fields.entries)
              TextField(
                controller: value,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: labels[key],
                  hintText: shared[key] == null
                      ? 'Different on each; empty keeps them'
                      : null,
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Saved in Nova only; the files and other apps keep their tags.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        if (edited)
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Reset'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, {
            for (final MapEntry(:key, :value) in fields.entries)
              key: value.text.trim(),
          }),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (answer == null) return null;
  if (answer == false) {
    await MusicLibrary().editTags(songs, null);
    return 'Tags reset to the files\' own.';
  }
  final changes = {
    for (final MapEntry(:key, :value)
        in (answer as Map<String, String>).entries)
      if (value.isNotEmpty && value != shared[key]) key: value,
  };
  if (changes.isEmpty) return null;
  await MusicLibrary().editTags(songs, changes);
  return 'Tags saved.';
}

/// Songs of [song]'s album in [library], which share its cover.
List<Song> _albumOf(Song song, List<Song> library) {
  if (song.album == 'Unknown album') return [song];
  final album = [
    for (final other in library)
      if (song.sameAlbum(other)) other,
  ];
  return album.isEmpty ? [song] : album;
}

/// Lets the user pick [song]'s cover among the albums MusicBrainz finds and
/// saves it for the whole album.
Future<void> _chooseCover(
  BuildContext context,
  Song song,
  List<Song> library,
  void Function(String message) notify,
) async {
  notify('Looking for the cover of ${song.album}...');
  final List<CoverChoice> choices;
  try {
    choices = await findCovers(song);
  } catch (_) {
    return notify('Could not reach MusicBrainz. Check your connection.');
  }
  if (choices.isEmpty) return notify('No cover found for ${song.album}.');
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  final choice = await showModalBottomSheet<CoverChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                'Pick the cover',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.8,
                children: [
                  for (final choice in choices)
                    InkWell(
                      onTap: () => Navigator.pop(sheetContext, choice),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: Image.network(
                              coverUrl(choice.id, size: 250).toString(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Center(child: Text('No cover')),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            choice.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  try {
    final cover = await downloadCover(choice.id);
    for (final track in _albumOf(song, library)) {
      await MusicLibrary().saveCover(track, cover);
    }
    notify('Saved the cover of ${song.album}.');
  } on HttpException {
    notify('${choice.title} has no cover. Pick another.');
  } catch (_) {
    notify('Could not download the cover. Check your connection.');
  }
}

/// Removes the saved cover from every song of [song]'s album.
Future<String> _removeCover(Song song, List<Song> library) async {
  for (final track in _albumOf(song, library)) {
    if (MusicLibrary.hasCover(track)) await MusicLibrary().removeCover(track);
  }
  return 'Removed the downloaded cover of ${song.album}.';
}

/// Ticks/unticks playlists for [songs]; stays open so several can be
/// changed. A playlist is ticked when it has all of them.
Future<void> showAddToPlaylist(BuildContext context, List<Song> songs) {
  FocusManager.instance.primaryFocus?.unfocus();
  final store = PlaylistStore.instance;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  songs.length == 1
                      ? 'Add "${songs.first.title}" to'
                      : 'Add ${songs.length} songs to',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Done'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('New playlist'),
                onTap: () async {
                  final name = await _askPlaylistName(sheetContext);
                  if (name != null && name.isNotEmpty) {
                    await store.addAll(name, songs);
                  }
                },
              ),
              for (final name in store.names)
                CheckboxListTile(
                  value: songs.every((song) => store.contains(name, song)),
                  title: Text(name),
                  subtitle: Text(_trackCount(store.lengthOf(name))),
                  onChanged: (checked) => checked == true
                      ? store.addAll(name, songs)
                      : store.removeAll(name, songs),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<String?> _askPlaylistName(
  BuildContext context, {
  String initial = '',
  String action = 'Create',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('New playlist'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: Text(action),
        ),
      ],
    ),
  );
}

/// m:ss, or h:mm:ss from an hour up.
String _clockLabel(Duration time) {
  final seconds = math.max(time.inSeconds, 0);
  String two(int value) => value.toString().padLeft(2, '0');
  final minutes = seconds ~/ 60;
  return minutes >= 60
      ? '${minutes ~/ 60}:${two(minutes % 60)}:${two(seconds % 60)}'
      : '$minutes:${two(seconds % 60)}';
}

Future<void> _showSleepSheet(
  BuildContext context,
  PlayerController controller,
) {
  void choose(BuildContext sheet, Duration? after) {
    controller.setSleepTimer(after);
    Navigator.pop(sheet);
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Pause playback after')),
          for (final minutes in const [15, 30, 45, 60])
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text('$minutes minutes'),
              onTap: () => choose(sheet, Duration(minutes: minutes)),
            ),
          ListTile(
            leading: const Icon(Icons.music_off_outlined),
            title: const Text('End of this song'),
            onTap: () => choose(sheet, null),
          ),
          if (controller.sleepTimerOn)
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Turn off timer'),
              onTap: () {
                controller.cancelSleepTimer();
                Navigator.pop(sheet);
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> showQueueSheet(BuildContext context, PlayerController controller) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DefaultTabController(
      length: 2,
      child: _QueueSheet(controller: controller),
    ),
  );
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final queue = controller.upcomingQueue;
        final upNext = controller.upNext;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Queue',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        controller.queueMode.description,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Queue'),
                    Tab(text: 'Recently played'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          if (controller.currentSong case final song?)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: ListTile(
                                leading: NovaArtwork(song: song, size: 48),
                                title: Text(
                                  controller.player.loopMode == LoopMode.one
                                      ? 'PLAYING NOW · ON REPEAT'
                                      : 'PLAYING NOW',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                subtitle: Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          const Divider(height: 24),
                          Expanded(
                            child: upNext.isEmpty
                                ? const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(32),
                                      child: Text(
                                        'Nothing plays after this song. Swipe a song left or use its menu to queue it.',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  )
                                : CustomScrollView(
                                    slivers: [
                                      if (queue.isNotEmpty) ...[
                                        _queueHeading(
                                          context,
                                          'QUEUED · ${queue.length}',
                                        ),
                                        // Long-press a queued song to drag it to a new position.
                                        SliverPadding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          sliver: SliverReorderableList(
                                            itemCount: queue.length,
                                            onReorderItem:
                                                controller.moveUpcoming,
                                            itemBuilder: (context, index) =>
                                                ReorderableDelayedDragStartListener(
                                                  // Index key: the same song may be queued twice.
                                                  key: ValueKey(index),
                                                  index: index,
                                                  child: Material(
                                                    type: MaterialType
                                                        .transparency,
                                                    child: _upNextTile(
                                                      context,
                                                      upNext,
                                                      index,
                                                      trailing: IconButton(
                                                        tooltip:
                                                            'Remove from queue',
                                                        onPressed: () =>
                                                            controller
                                                                .removeUpcomingAt(
                                                                  index,
                                                                ),
                                                        icon: const Icon(
                                                          Icons.close_rounded,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ],
                                      if (upNext.length > queue.length) ...[
                                        _queueHeading(
                                          context,
                                          queue.isEmpty ? 'UP NEXT' : 'THEN',
                                        ),
                                        SliverPadding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          sliver: SliverList.builder(
                                            itemCount:
                                                upNext.length - queue.length,
                                            itemBuilder: (context, index) =>
                                                _upNextTile(
                                                  context,
                                                  upNext,
                                                  queue.length + index,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                          ),
                        ],
                      ),
                      _RecentlyPlayed(controller: controller),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _queueHeading(BuildContext context, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: 1.2),
      ),
    ),
  );

  /// A song in [upNext]; the first one is marked as playing next, unless
  /// Repeat One plays the current song again.
  Widget _upNextTile(
    BuildContext context,
    List<Song> upNext,
    int index, {
    Widget? trailing,
  }) {
    final song = upNext[index];
    final colors = Theme.of(context).colorScheme;
    final isNext = index == 0 && controller.player.loopMode != LoopMode.one;
    return ListTile(
      leading: NovaArtwork(song: song, size: 46),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        isNext ? 'Next · ${song.artist}' : '${song.artist} · ${song.format}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isNext
            ? TextStyle(color: colors.primary, fontWeight: FontWeight.w700)
            : null,
      ),
      trailing: trailing,
      onTap: () => controller.playUpNext(index),
    );
  }
}

/// Songs played before, newest first, from the listening history.
class _RecentlyPlayed extends StatefulWidget {
  const _RecentlyPlayed({required this.controller});

  final PlayerController controller;

  @override
  State<_RecentlyPlayed> createState() => _RecentlyPlayedState();
}

class _RecentlyPlayedState extends State<_RecentlyPlayed> {
  late final _history = ListeningHistory.instance.load();

  Future<void> _play(Song song) async {
    final controller = widget.controller;
    final wasPlaying = controller.currentSong != null;
    // Plays it now and keeps the queue: it goes first in line, then we skip.
    await controller.playNext(song);
    if (wasPlaying) await controller.next();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PlayRecord>>(
      future: _history,
      builder: (context, snapshot) {
        final history = snapshot.data;
        if (history == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final songs = recentlyPlayed(history, widget.controller.library);
        if (songs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Songs you play will show up here.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: songs.length,
          itemBuilder: (context, index) {
            final song = songs[index];
            return ListTile(
              leading: NovaArtwork(song: song, size: 46),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _play(song),
            );
          },
        );
      },
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.initialMode,
    required this.themeController,
    required this.onModeChanged,
    required this.onReload,
    required this.onFindDuplicates,
    required this.equalizer,
    required this.songCount,
  });

  final QueueMode initialMode;
  final ThemeController themeController;
  final Future<void> Function(QueueMode mode) onModeChanged;

  /// Reloads the library on the home screen.
  final Future<void> Function() onReload;
  final VoidCallback onFindDuplicates;
  final AndroidEqualizer? equalizer;
  final int Function() songCount;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late QueueMode _mode;
  String? _lyricsFolder;
  List<({String uri, String name})> _musicFolders = const [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    widget.themeController.addListener(_themeChanged);
    MusicLibrary().lyricsFolder().then((folder) {
      if (mounted) setState(() => _lyricsFolder = folder);
    });
    _refreshFolders();
  }

  Future<void> _refreshFolders() async {
    final folders = await MusicLibrary().musicFolders();
    if (mounted) setState(() => _musicFolders = folders);
  }

  /// Re-indexes storage (when [reindex]) and reloads the library, reporting the result.
  Future<void> _rescan({bool reindex = true}) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    final before = widget.songCount();
    try {
      if (reindex) await MusicLibrary().rescanStorage();
      await widget.onReload();
      final after = widget.songCount();
      final change = after - before;
      _notify(
        'Library has ${_trackCount(after)}'
        '${change == 0 ? '' : ' (${change > 0 ? '+' : ''}$change)'}.',
      );
    } catch (_) {
      _notify('Rescan failed. Try again.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _backUp() async {
    try {
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final saved = await MusicLibrary().saveTextFile(
        'nova-backup-$day.json',
        'application/json',
        await createBackup(),
      );
      if (saved) _notify('Backup saved');
    } catch (_) {
      _notify('The backup could not be saved.');
    }
  }

  Future<void> _restore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore a backup?'),
        content: const Text(
          'Your playlists, settings and listening history are replaced by '
          'the backup, then Nova restarts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Pick backup'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final text = await MusicLibrary().openTextFile();
      if (text == null) return;
      await restoreBackup(text);
      await MusicLibrary().restartApp();
    } on FormatException {
      _notify('That file is not a Nova backup. Nothing was changed.');
    } catch (_) {
      _notify('The backup could not be read.');
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickLyricsFolder() async {
    final folder = await MusicLibrary().pickLyricsFolder();
    if (mounted) setState(() => _lyricsFolder = folder);
  }

  Future<void> _clearLyricsFolder() async {
    await MusicLibrary().clearLyricsFolder();
    if (mounted) setState(() => _lyricsFolder = null);
  }

  void _themeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.themeController.removeListener(_themeChanged);
    super.dispose();
  }

  Future<void> _select(QueueMode mode) async {
    setState(() => _mode = mode);
    await widget.onModeChanged(mode);
  }

  void _open(String title, Widget Function(BuildContext context) body) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListenableBuilder(
            listenable: widget.themeController,
            builder: (context, _) => body(context),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themes = widget.themeController;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Appearance'),
            subtitle: Text('${themes.preset.name} / ${themes.mode.name}'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open('Appearance', _appearance),
          ),
          ListTile(
            leading: const Icon(Icons.text_fields_rounded),
            title: const Text('Font'),
            subtitle: Text(themes.font.name),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open('Font', _fonts),
          ),
          ListTile(
            leading: const Icon(Icons.format_size_rounded),
            title: const Text('Text size'),
            subtitle: Text(
              textScales.entries
                      .where((entry) => entry.value == themes.textScale)
                      .firstOrNull
                      ?.key ??
                  'Custom',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open('Text size', _sizes),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Music folders'),
            subtitle: Text(
              _musicFolders.isEmpty
                  ? 'Add folders Android does not index'
                  : '${_musicFolders.length} extra '
                        '${_musicFolders.length == 1 ? 'folder' : 'folders'}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open('Music folders', _folders),
          ),
          ListTile(
            leading: _scanning
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.refresh_rounded),
            title: const Text('Rescan library'),
            subtitle: Text(
              _scanning
                  ? 'Scanning your phone and SD card...'
                  : 'Find new, moved or deleted songs',
            ),
            onTap: _scanning ? null : _rescan,
          ),
          if (widget.equalizer case final equalizer?)
            ListTile(
              leading: const Icon(Icons.equalizer_rounded),
              title: const Text('Equalizer'),
              subtitle: Text(equalizer.enabled ? 'On' : 'Off'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EqualizerPage(equalizer: equalizer),
                  ),
                );
                if (mounted) setState(() {});
              },
            ),
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: const Text('Translation languages'),
            subtitle: const Text('Delete downloaded language packs'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const TranslationModelsPage(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt_rounded),
            title: const Text('Back up'),
            subtitle: const Text(
              'Save playlists, settings and stats to a file',
            ),
            onTap: _backUp,
          ),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore_rounded),
            title: const Text('Restore backup'),
            subtitle: const Text('Replace everything with a saved backup'),
            onTap: _restore,
          ),
          ListTile(
            leading: const Icon(Icons.content_copy_rounded),
            title: const Text('Duplicates'),
            subtitle: const Text('Find the same song in several files'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: widget.onFindDuplicates,
          ),
          ListTile(
            leading: const Icon(Icons.lyrics_outlined),
            title: const Text('Lyrics folder'),
            subtitle: Text(
              _lyricsFolder ??
                  'Not set. Pick a folder with .lrc files to use them.',
            ),
            trailing: _lyricsFolder == null
                ? const Icon(Icons.chevron_right_rounded)
                : IconButton(
                    tooltip: 'Stop using this folder',
                    onPressed: _clearLyricsFolder,
                    icon: const Icon(Icons.close_rounded),
                  ),
            onTap: _pickLyricsFolder,
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded),
            title: const Text('Queue'),
            subtitle: Text(_mode.title),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _open('Queue', _queue),
          ),
        ],
      ),
    );
  }

  Widget _appearance(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        const SizedBox(height: 12),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_rounded),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_rounded),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_rounded),
              label: Text('Dark'),
            ),
          ],
          selected: {widget.themeController.mode},
          onSelectionChanged: (selection) {
            widget.themeController.selectMode(selection.first);
          },
        ),
        const SizedBox(height: 18),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.themeController.allThemes.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.25,
          ),
          itemBuilder: (context, index) {
            final preset = widget.themeController.allThemes[index];
            final selected = widget.themeController.preset.id == preset.id;
            return Semantics(
              button: true,
              selected: selected,
              label: '${preset.name} theme',
              child: InkWell(
                onTap: () => widget.themeController.selectPreset(preset),
                borderRadius: BorderRadius.circular(20),
                child: Ink(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: preset.background,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? preset.primary
                          : preset.foreground.withValues(alpha: 0.2),
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          _ThemeDot(color: preset.primary),
                          const SizedBox(width: 6),
                          _ThemeDot(color: preset.secondary),
                          const Spacer(),
                          if (selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: preset.primary,
                              size: 20,
                            ),
                        ],
                      ),
                      // Shows the selected font in this theme's colors.
                      Text(
                        'Aa',
                        style: TextStyle(
                          color: preset.foreground,
                          fontSize: 26,
                        ),
                      ),
                      Text(
                        preset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: preset.foreground,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: () {
            _catalog = fetchThemeCatalog();
            _open('Get themes', _themeStore);
          },
          icon: const Icon(Icons.download_rounded),
          label: const Text('Get more themes'),
        ),
      ],
    );
  }

  Future<List<AppThemePreset>>? _catalog;

  Widget _themeStore(BuildContext context) {
    final themes = widget.themeController;
    return FutureBuilder(
      future: _catalog,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final catalog = snapshot.data ?? const <AppThemePreset>[];
        // Installed themes stay removable even if the catalog dropped them.
        final shown = [
          ...catalog,
          ...themes.downloadedThemes.where(
            (theme) => catalog.every((item) => item.id != theme.id),
          ),
        ];
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (snapshot.hasError)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Could not load the theme catalog. Check your internet '
                  'connection and try again.',
                ),
              ),
            for (final preset in shown)
              Card(
                color: preset.background,
                child: ListTile(
                  leading: _ThemeDot(color: preset.primary),
                  title: Text(
                    preset.name,
                    style: TextStyle(
                      color: preset.foreground,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    preset.brightness == Brightness.light ? 'Light' : 'Dark',
                    style: TextStyle(color: preset.secondary),
                  ),
                  trailing:
                      themes.downloadedThemes.any((t) => t.id == preset.id)
                      ? TextButton(
                          onPressed: () => themes.removeTheme(preset),
                          child: Text(
                            'Remove',
                            style: TextStyle(color: preset.primary),
                          ),
                        )
                      : FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: preset.primary,
                            foregroundColor: preset.background,
                          ),
                          onPressed: () async {
                            await themes.installTheme(preset);
                            await themes.selectPreset(preset);
                          },
                          child: const Text('Install'),
                        ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _downloadFont(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _FontNameDialog(),
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)
      ..showSnackBar(SnackBar(content: Text('Downloading ${name.trim()}...')));
    try {
      await widget.themeController.installFont(name.trim());
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Installed ${name.trim()}')));
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Could not download "${name.trim()}". Check the name on '
              'fonts.google.com and your internet connection.',
            ),
          ),
        );
    }
  }

  // Rebuilt by StatefulBuilder so the radio marks update inside the sub-page route.
  Widget _queue(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setPageState) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          for (final mode in QueueMode.values)
            _ChoiceCard(
              selected: _mode == mode,
              title: Text(mode.title),
              body: Text(mode.description),
              onTap: () async {
                final saved = _select(mode);
                setPageState(() {});
                await saved;
              },
            ),
        ],
      ),
    );
  }

  // StatefulBuilder: the sub-page route does not rebuild with this State.
  Widget _folders(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setPageState) {
        Future<void> change(Future<void> Function() action) async {
          await action();
          await _refreshFolders();
          setPageState(() {});
          await _rescan(reindex: false);
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              'Nova already finds every song Android has indexed on your '
              'phone and SD card. Add a folder here to also include music '
              'Android skips, such as folders with a .nomedia file.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            for (final folder in _musicFolders)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_rounded),
                  title: Text(folder.name),
                  trailing: IconButton(
                    tooltip: 'Remove folder',
                    onPressed: () => change(
                      () => MusicLibrary().removeMusicFolder(folder.uri),
                    ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => change(() async {
                await MusicLibrary().addMusicFolder();
              }),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
            ),
          ],
        );
      },
    );
  }

  Widget _fonts(BuildContext context) {
    final themes = widget.themeController;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        for (final font in themes.allFonts)
          _ChoiceCard(
            selected: themes.font.id == font.id,
            trailing: themes.downloadedFonts.contains(font)
                ? IconButton(
                    tooltip: 'Remove ${font.name}',
                    onPressed: () => themes.removeFont(font),
                    icon: const Icon(Icons.delete_outline_rounded),
                  )
                : null,
            // 'Roboto' is Android's platform font, so System previews as itself.
            title: Text(
              font.name,
              style: TextStyle(fontFamily: font.family ?? 'Roboto'),
            ),
            body: Text(
              'The quick brown fox jumps over the lazy dog. 0123456789',
              style: TextStyle(fontFamily: font.family ?? 'Roboto'),
            ),
            onTap: () => themes.selectFont(font),
          ),
        OutlinedButton.icon(
          onPressed: () => _downloadFont(context),
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download a font'),
        ),
      ],
    );
  }

  Widget _sizes(BuildContext context) {
    final themes = widget.themeController;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        for (final entry in textScales.entries)
          _ChoiceCard(
            selected: themes.textScale == entry.value,
            title: Text(entry.key),
            body: Text('${(entry.value * 100).round()}% of the normal size'),
            onTap: () => themes.selectTextScale(entry.value),
          ),
      ],
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.selected,
    required this.title,
    required this.body,
    required this.onTap,
    this.trailing,
  });

  final bool selected;
  final Widget title;
  final Widget body;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        selected: selected,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle.merge(
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                          child: title,
                        ),
                        const SizedBox(height: 6),
                        DefaultTextStyle.merge(
                          style: TextStyle(color: colors.onSurfaceVariant),
                          child: body,
                        ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeDot extends StatelessWidget {
  const _ThemeDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _FontNameDialog extends StatefulWidget {
  const _FontNameDialog();

  @override
  State<_FontNameDialog> createState() => _FontNameDialogState();
}

class _FontNameDialogState extends State<_FontNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download a font'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Any font family from fonts.google.com.'),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Font name'),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final name in suggestedFonts)
                  ActionChip(
                    label: Text(name),
                    onPressed: () => Navigator.pop(context, name),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text),
          child: const Text('Download'),
        ),
      ],
    );
  }
}

/// Long-press selection of several songs, with a bar of actions for them.
mixin _SongSelection<T extends StatefulWidget> on State<T> {
  /// Ids of the ticked songs; selecting while not empty.
  final Set<String> selectedIds = {};

  /// The songs on screen in order; Select all and the actions follow it.
  List<Song> get selectableSongs;

  PlayerController get selectionPlayer;

  /// Set on a playlist's page, to remove songs from it.
  String? get selectionPlaylist => null;

  bool get selecting => selectedIds.isNotEmpty;

  void toggleSelected(Song song) {
    if (!selecting) HapticFeedback.selectionClick();
    setState(() {
      if (!selectedIds.remove(song.id)) selectedIds.add(song.id);
    });
  }

  List<Song> get _selection => [
    for (final song in selectableSongs)
      if (selectedIds.contains(song.id)) song,
  ];

  /// The ticked songs in list order; clears the selection.
  List<Song> _takeSelection() {
    final songs = _selection;
    setState(selectedIds.clear);
    return songs;
  }

  void _notify(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: action,
          duration: const Duration(seconds: 8),
        ),
      );
  }

  /// Back leaves selection before it leaves the page.
  Widget selectionScope(Widget child) => PopScope(
    canPop: !selecting,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) setState(selectedIds.clear);
    },
    child: child,
  );

  Future<void> _queueSelection() async {
    final songs = _takeSelection();
    try {
      for (final song in songs) {
        await selectionPlayer.addToQueue(song);
      }
      _notify('Added ${_trackCount(songs.length)} to queue');
    } catch (_) {
      _notify('Could not update the queue.');
    }
  }

  Future<void> _removeSelection(String playlist) async {
    final songs = _takeSelection();
    await PlaylistStore.instance.removeAll(playlist, songs);
    _notify('Removed ${_trackCount(songs.length)} from $playlist');
  }

  Future<void> _trashSelection() async {
    final songs = _selection;
    final library = MusicLibrary();
    try {
      if (!await library.trashSongs(songs)) return;
    } on PlatformException catch (error) {
      return _notify(error.message ?? 'Could not delete the songs.');
    } catch (_) {
      return _notify('Could not delete the songs.');
    }
    if (mounted) setState(selectedIds.clear);
    _notify(
      'Moved ${_trackCount(songs.length)} to the trash',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => library
            .trashSongs(songs, restore: true)
            .catchError((Object _) => false),
      ),
    );
  }

  Widget selectionBar() {
    final playlist = selectionPlaylist;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel selection',
              onPressed: () => setState(selectedIds.clear),
              icon: const Icon(Icons.close_rounded),
            ),
            Expanded(child: Text('${selectedIds.length} selected')),
            IconButton(
              tooltip: 'Select all',
              onPressed: () => setState(
                () => selectedIds.addAll(selectableSongs.map((s) => s.id)),
              ),
              icon: const Icon(Icons.select_all_rounded),
            ),
            IconButton(
              tooltip: 'Add to queue',
              onPressed: _queueSelection,
              icon: const Icon(Icons.queue_music_rounded),
            ),
            IconButton(
              tooltip: 'Add to playlist',
              onPressed: () => showAddToPlaylist(context, _takeSelection()),
              icon: const Icon(Icons.playlist_add_rounded),
            ),
            IconButton(
              tooltip: 'Edit tags',
              onPressed: () => _editTags(
                context,
                _takeSelection(),
              ).then((message) => message == null ? null : _notify(message)),
              icon: const Icon(Icons.edit_outlined),
            ),
            if (playlist != null)
              IconButton(
                tooltip: 'Remove from $playlist',
                onPressed: () => _removeSelection(playlist),
                icon: const Icon(Icons.playlist_remove_rounded),
              ),
            IconButton(
              tooltip: 'Move to trash',
              onPressed: _trashSelection,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
