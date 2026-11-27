import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../core/protocol.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'expressive.dart';

/// Material 3 Expressive icon button sizes (Compose's IconButton tokens:
/// medium 56dp with a 24dp icon, large 96dp with a 32dp icon).
ButtonStyle iconButtonSize(double container, double icon) => IconButton.styleFrom(
  fixedSize: Size.square(container),
  minimumSize: Size.square(container),
  iconSize: icon,
  padding: EdgeInsets.zero,
);

/// How far the player is through what it plays, 0 to 1, as it changes.
class _Progress extends StatelessWidget {
  const _Progress({required this.player, required this.builder});
  final mk.Player player;
  final Widget Function(BuildContext context, Duration at, Duration total) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: player.stream.position,
    initialData: player.state.position,
    builder: (context, pos) => builder(context, pos.data ?? Duration.zero, player.state.duration),
  );
}

// ---- on a card ------------------------------------------------------------------

/// An audio file on a card: a play button, its name, and while it plays a
/// slim progress line and the time. The rest of the card still opens the
/// note.
class CardAudio extends ConsumerWidget {
  const CardAudio(this.attachment, {super.key, required this.ink});
  final Attachment attachment;
  final Color ink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final a = attachment;
    return PlaybackBuilder(
      attachment: a,
      builder: (context, deck, mine, playing) => Row(
        children: [
          IconButton.filledTonal(
            tooltip: playing ? 'Pause' : 'Play ${a.name}',
            onPressed: () => togglePlayback(ref, a),
            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(color: ink),
                ),
                const SizedBox(height: 6),
                if (!mine)
                  Text(kindLabel(a), style: text.labelSmall?.copyWith(color: ink.withValues(alpha: 0.7)))
                else
                  _Progress(
                    player: deck.player,
                    builder: (context, at, total) {
                      final ms = total.inMilliseconds;
                      return Row(
                        children: [
                          // the wave travels while it plays, and rests on pause
                          Expanded(
                            child: WavyProgress(
                              value: ms == 0 ? 0 : (at.inMilliseconds / ms).clamp(0.0, 1.0),
                              moving: playing,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatDuration(ms == 0 ? at : total - at),
                            style: text.labelSmall?.copyWith(color: ink.withValues(alpha: 0.7)),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A video on a card (or in a note): a 16:9 tile that plays in place.
/// Before it plays, a dark tile with a play button and its name; playing,
/// the picture, paused or played by a tap, with a slim progress line and a
/// button to open it full screen (where it keeps playing).
class InlineVideo extends ConsumerStatefulWidget {
  const InlineVideo(this.attachment, {super.key});
  final Attachment attachment;

  @override
  ConsumerState<InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends ConsumerState<InlineVideo> {
  late final MediaDeck _deck = ref.read(mediaDeckProvider);

  @override
  void initState() {
    super.initState();
    _deck.showing(widget.attachment.id);
  }

  @override
  void dispose() {
    _deck.hidden(widget.attachment.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: PlaybackBuilder(
        attachment: a,
        builder: (context, deck, mine, playing) {
          if (!mine) {
            // not started: a tile in the card's highest surface tone, which
            // reads as a tile on any background
            // the button in the room above the caption, never under it; on
            // a tile too short for both at full size, the button steps down
            return ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: LayoutBuilder(
                builder: (context, box) => Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: IconButton.filled(
                          tooltip: 'Play ${a.name}',
                          style: box.maxHeight < 104 ? iconButtonSize(40, 24) : iconButtonSize(56, 24),
                          onPressed: () => togglePlayback(ref, a),
                          icon: const Icon(Icons.play_arrow_rounded),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Row(
                        children: [
                          Icon(Icons.movie_outlined, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: () => togglePlayback(ref, a),
                  child: Video(controller: deck.video, controls: NoVideoControls, fill: Colors.black),
                ),
                // while it is fetched, the loading indicator stands where
                // the play button was: a play button there reads as a
                // missed tap, and has nothing to play yet
                ValueListenableBuilder(
                  valueListenable: deck.loading,
                  builder: (context, loading, _) => loading != null
                      ? const Center(child: LoadingIndicator(contained: true))
                      : playing
                      ? const SizedBox.shrink()
                      : Center(
                          child: IconButton.filled(
                            tooltip: 'Play',
                            style: iconButtonSize(56, 24),
                            onPressed: () => togglePlayback(ref, a),
                            icon: const Icon(Icons.play_arrow_rounded),
                          ),
                        ),
                ),
                // bottom end, clear of the card's selection check, on a scrim
                // so it shows over any picture
                Positioned(
                  right: 4,
                  bottom: 8,
                  child: IconButton(
                    tooltip: 'Full screen',
                    style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                    onPressed: () => openAttachment(context, a),
                    icon: const Icon(Icons.fullscreen),
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: deck.loading,
                  builder: (context, loading, _) => Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: loading != null
                        ? LinearProgressIndicator(value: loading == 0 ? null : loading, minHeight: 4)
                        : _Progress(
                            player: deck.player,
                            builder: (context, at, total) {
                              final ms = total.inMilliseconds;
                              return LinearProgressIndicator(
                                value: ms == 0 ? 0 : (at.inMilliseconds / ms).clamp(0.0, 1.0),
                                minHeight: 4,
                                color: scheme.primary,
                                backgroundColor: Colors.white24,
                              );
                            },
                          ),
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

// ---- full screen -----------------------------------------------------------------

/// A video full screen, on the app's one player (so one started on a card
/// carries on here). The controls are Material's media pattern: a large
/// play button between back 10 and forward 10, a seek bar with the times
/// on a scrim; they fade while it plays, and come back on a tap or a move.
class VideoView extends ConsumerStatefulWidget {
  const VideoView(this.attachment, {super.key});
  final Attachment attachment;

  @override
  ConsumerState<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<VideoView> {
  late final MediaDeck _deck = ref.read(mediaDeckProvider);
  bool _shown = true;
  Timer? _hide;
  StreamSubscription<bool>? _playing;

  @override
  void initState() {
    super.initState();
    _deck.showing(widget.attachment.id);
    // start it, unless it is already the one playing (opened from a card)
    final media = ref.read(mediaProvider);
    if (_deck.current.value != widget.attachment.id && media != null) {
      unawaited(_deck.toggle(widget.attachment, media));
    }
    _playing = _deck.player.stream.playing.listen((p) => p ? _poke() : _show());
    _poke();
  }

  @override
  void dispose() {
    _hide?.cancel();
    unawaited(_playing?.cancel());
    _deck.hidden(widget.attachment.id);
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    if (mounted) setState(() => _shown = true);
  }

  /// Shows the controls, and hides them again after a while if playing.
  void _poke() {
    _show();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && _deck.player.state.playing) setState(() => _shown = false);
    });
  }

  Future<void> _skip(int seconds) async {
    await _deck.skip(seconds);
    _poke();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () => togglePlayback(ref, a),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-10),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(10),
      },
      child: MouseRegion(
        onHover: (_) => _poke(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _shown && _deck.player.state.playing ? setState(() => _shown = false) : _poke(),
          child: PlaybackBuilder(
            attachment: a,
            builder: (context, deck, mine, playing) => Stack(
              fit: StackFit.expand,
              children: [
                if (mine) Video(controller: deck.video, controls: NoVideoControls, fill: Colors.black),
                IgnorePointer(
                  ignoring: !_shown,
                  child: AnimatedOpacity(
                    opacity: _shown ? 1 : 0,
                    duration: Durations.medium2,
                    curve: Easing.standard,
                    child: TickerMode(
                      // hidden, the seek bar's wave stops too
                      enabled: _shown,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 24,
                              children: [
                                IconButton(
                                  tooltip: 'Back 10 seconds',
                                  color: Colors.white,
                                  style: iconButtonSize(56, 32),
                                  onPressed: mine ? () => _skip(-10) : null,
                                  icon: const Icon(Icons.replay_10_rounded),
                                ),
                                // while it is fetched, the loading indicator
                                // in the play button's place
                                ValueListenableBuilder(
                                  valueListenable: deck.loading,
                                  builder: (context, loading, _) => mine && loading != null
                                      ? const LoadingIndicator(size: 96, contained: true)
                                      : IconButton.filled(
                                          tooltip: playing ? 'Pause' : 'Play',
                                          style: iconButtonSize(96, 32),
                                          onPressed: () => togglePlayback(ref, a),
                                          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                        ),
                                ),
                                IconButton(
                                  tooltip: 'Forward 10 seconds',
                                  color: Colors.white,
                                  style: iconButtonSize(56, 32),
                                  onPressed: mine ? () => _skip(10) : null,
                                  icon: const Icon(Icons.forward_10_rounded),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Color(0x00000000), Color(0xB3000000)],
                                ),
                              ),
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
                                  // how far the fetch is, where the seek bar
                                  // will be
                                  child: DeckSeekBar(deck: deck, mine: mine, color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
