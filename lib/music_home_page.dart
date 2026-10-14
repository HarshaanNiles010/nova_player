import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'package:flutter/rendering.dart';

import 'downloads.dart';
import 'group_by.dart';
import 'listening_history.dart';
import 'lyrics.dart';
import 'music_library.dart';
import 'player_controller.dart';
import 'playlists.dart';
import 'queue_mode.dart';
import 'settings_store.dart';
import 'smart_playlists.dart';
import 'song.dart';
import 'stats_page.dart';
import 'theme.dart';
import 'waveform.dart';

class MusicHomePage extends StatefulWidget {
  const MusicHomePage({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage> {
  final _library = MusicLibrary();
  final _player = PlayerController();
  final _settings = SettingsStore();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  GroupBy _groupBy = GroupBy.none;

  Map<String, List<Song>> _groupsOf(List<Song> songs) =>
      groupSongs(songs, _groupBy.keyFor);

  /// Playback order matching the list on screen; cached so playAt keeps the
  /// same instance and does not reload the player on every tap.
  List<Song> _playOrder = const [];

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
    _initialize();
  }

  Future<void> _initialize() async {
    // Before anything plays: a newer checkpoint would overwrite the leftover one.
    await ListeningHistory.instance.recoverPending();
    await _player.setQueueMode(await _settings.loadQueueMode());
    _groupBy = await _settings.loadGroupBy();
    await _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs = await _library.loadSongs();
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
    _searchController.dispose();
    _scrollController.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: NovaDrawer(
        onTracks: () => Navigator.pop(context),
        onAlbums: () =>
            _openLibraryPage(AlbumsPage(songs: _songs, player: _player)),
        onArtists: () =>
            _openLibraryPage(ArtistsPage(songs: _songs, player: _player)),
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
            message:
                'Add audio files to your phone or memory card, then refresh.',
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
              onTap: () => _play(song),
              onQueue: () => _addToQueue(song),
              onLongPress: () =>
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
  });

  final Song song;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onQueue;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Swipe left to queue; returning false snaps the tile back into place.
    return Dismissible(
      key: ValueKey('queue-swipe-${song.id}'),
      direction: DismissDirection.endToStart,
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
          minTileHeight: 72,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: NovaArtwork(song: song, size: 44),
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
      child: FutureBuilder<Uint8List?>(
        future: MusicLibrary().loadThumbnail(song.uri, pixels),
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
          final artworkSize = math.min(
            MediaQuery.sizeOf(context).width - 48,
            380.0,
          );
          return Scaffold(
            appBar: AppBar(
              title: const Text(
                'NOW PLAYING',
                style: TextStyle(fontSize: 12, letterSpacing: 2.4),
              ),
              centerTitle: true,
              actions: [
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                child: Column(
                  children: [
                    _DeviceArtwork(song: song, size: artworkSize),
                    const SizedBox(height: 30),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            song.title,
                            maxLines: 2,
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
                                (other) => other.album == song.album,
                              ),
                              child: Text(song.album),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),
                    _WaveformSeekBar(controller: controller, song: song),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          tooltip: 'Shuffle',
                          color: controller.player.shuffleModeEnabled
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
                          padding: const EdgeInsets.all(18),
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
    _lines = MusicLibrary().loadLyrics(widget.song).then((raw) {
      final lines = raw == null ? const <LyricLine>[] : parseLyrics(raw);
      _keys = List.generate(lines.length, (_) => GlobalKey());
      return lines;
    });
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
          return const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No lyrics found for this song',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          );
        }
        final synced = lines.first.time != null;
        return StreamBuilder<Duration>(
          stream: synced
              ? widget.controller.player.positionStream
              : const Stream.empty(),
          builder: (context, position) {
            final active = synced
                ? activeLyricIndex(lines, position.data ?? Duration.zero)
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
                Text(
                  'LYRICS',
                  key: _headerKey,
                  style: const TextStyle(fontSize: 12, letterSpacing: 2.4),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < lines.length; i++)
                  InkWell(
                    key: _keys[i],
                    onTap: lines[i].time == null
                        ? null
                        : () => widget.controller.player.seek(lines[i].time),
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
                        child: Text(
                          lines[i].text.isEmpty ? '♪' : lines[i].text,
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
    return FutureBuilder<Uint8List?>(
      // Sized thumbnail: MediaStore caches it, unlike the full embedded image.
      future: MusicLibrary().loadThumbnail(song.uri, pixels),
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
    );
  }
}

class _WaveformSeekBar extends StatelessWidget {
  const _WaveformSeekBar({required this.controller, required this.song});

  final PlayerController controller;
  final Song song;

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
              height: 72,
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
    required this.onPlaylists,
    required this.onSmartPlaylists,
    required this.onStats,
    required this.onQueue,
    required this.onSettings,
  });

  final VoidCallback onTracks;
  final VoidCallback onAlbums;
  final VoidCallback onArtists;
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
      groups: groupSongs(songs, (song) => song.album),
      player: player,
      detail: (tracks) => tracks.first.artist,
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
        final albums = tracks.map((song) => song.album).toSet().length;
        return '$albums ${albums == 1 ? 'album' : 'albums'}';
      },
    );
  }
}

class _GroupedLibraryPage extends StatelessWidget {
  const _GroupedLibraryPage({
    required this.title,
    required this.groups,
    required this.player,
    required this.detail,
  });

  final String title;
  final Map<String, List<Song>> groups;
  final PlayerController player;
  final String Function(List<Song> tracks) detail;

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
                return InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SongCollectionPage(
                        title: entry.key,
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
                        entry.key,
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

class SongCollectionPage extends StatelessWidget {
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

  /// Set when showing a playlist, so long-press offers "Remove from playlist".
  final String? playlist;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, letterSpacing: 1.6),
        ),
        actions: actions,
      ),
      body: playlist == null
          ? ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              itemCount: songs.length + 1,
              itemBuilder: (context, index) =>
                  index == 0 ? _header(context) : _tile(context, index - 1),
            )
          // Drag handles, since long-press already opens the song menu.
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              header: _header(context),
              buildDefaultDragHandles: false,
              itemCount: songs.length,
              onReorderItem: (from, to) {
                final ordered = [...songs];
                ordered.insert(to, ordered.removeAt(from));
                PlaylistStore.instance.reorder(playlist!, ordered);
              },
              itemBuilder: (context, index) => Row(
                key: ValueKey(songs[index].id),
                children: [
                  Expanded(child: _tile(context, index)),
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

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
    child: Row(
      children: [
        _DeviceArtwork(song: songs.first, size: 96),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            subtitle.toUpperCase(),
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

  Widget _tile(BuildContext context, int index) {
    final song = songs[index];
    return SongTile(
      song: song,
      active: player.currentSong?.id == song.id,
      onTap: () async {
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
      onLongPress: () => showSongActions(
        context,
        song: song,
        player: player,
        playlist: playlist,
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

  @override
  Widget build(BuildContext context) {
    final store = PlaylistStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('My Playlists')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final names = store.names;
          if (names.isEmpty) {
            return const _LibraryMessage(
              icon: Icons.library_music_rounded,
              title: 'No playlists yet',
              message: 'Long-press any song and choose Add to playlist.',
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
                                message: 'Long-press any song and choose Add to playlist.',
                              ),
                            );
                          }
                          return SongCollectionPage(
                            title: name,
                            subtitle: _trackCount(songs.length),
                            songs: songs,
                            player: player,
                            playlist: name,
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
        ],
      ),
    );
  }
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
                  showAddToPlaylist(context, song);
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
                leading: const Icon(Icons.album_outlined),
                title: const Text('Go to album'),
                subtitle: Text(song.album),
                onTap: () =>
                    open(song.album, (other) => other.album == song.album),
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

/// Ticks/unticks playlists for [song]; stays open so several can be changed.
Future<void> showAddToPlaylist(BuildContext context, Song song) {
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
                  'Add "${song.title}" to',
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
                    await store.add(name, song);
                  }
                },
              ),
              for (final name in store.names)
                CheckboxListTile(
                  value: store.contains(name, song),
                  title: Text(name),
                  subtitle: Text(_trackCount(store.lengthOf(name))),
                  onChanged: (checked) => checked == true
                      ? store.add(name, song)
                      : store.remove(name, song),
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

Future<void> showQueueSheet(BuildContext context, PlayerController controller) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _QueueSheet(controller: controller),
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
                if (controller.currentSong case final song?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ListTile(
                      leading: NovaArtwork(song: song, size: 48),
                      title: const Text(
                        'PLAYING NOW',
                        style: TextStyle(
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'UP NEXT · ${queue.length}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: queue.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Your queue is empty. Swipe a song left or use its menu to add it.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      // Long-press a song to drag it to a new position.
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: queue.length,
                          onReorderItem: controller.moveUpcoming,
                          itemBuilder: (context, index) {
                            final song = queue[index];
                            return ListTile(
                              // Index key: the same song may be queued twice.
                              key: ValueKey(index),
                              leading: NovaArtwork(song: song, size: 46),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${song.artist} · ${song.format}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                tooltip: 'Remove from queue',
                                onPressed: () =>
                                    controller.removeUpcomingAt(index),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
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
    required this.songCount,
  });

  final QueueMode initialMode;
  final ThemeController themeController;
  final Future<void> Function(QueueMode mode) onModeChanged;

  /// Reloads the library on the home screen.
  final Future<void> Function() onReload;
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
