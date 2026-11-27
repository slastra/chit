/// The app's one media player, and what every player view shares: its
/// seek bar and time format.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../state/providers.dart';
import 'expressive.dart';
import 'feedback.dart';

/// The app's one player, audio and video alike: starting one stops
/// whatever played before, and a video started on a card carries on full
/// screen.
final class MediaDeck {
  MediaDeck() : player = mk.Player();

  /// media_kit's player. Its libmpv setup (no Lua scripts, stereo output)
  /// lives in the patched copy: third_party/media_kit/CHIT.md.
  final mk.Player player;
  final current = ValueNotifier<String?>(null);
  final loading = ValueNotifier<double?>(null);

  /// The picture, made the first time a video plays.
  VideoController get video => _video ??= VideoController(player);
  VideoController? _video;

  /// How many views show each video, so one whose last view goes away (a
  /// card scrolled off, the viewer closed) is paused, not heard unseen.
  final _views = <String, int>{};

  void showing(String id) => _views[id] = (_views[id] ?? 0) + 1;

  void hidden(String id) {
    final n = (_views[id] ?? 1) - 1;
    if (n > 0) {
      _views[id] = n;
      return;
    }
    _views.remove(id);
    if (current.value == id) unawaited(player.pause());
  }

  /// Counts the starts, so a slow one overtaken by another (or by [stop])
  /// leaves the newer one's state alone.
  int _turn = 0;

  Future<void> toggle(Attachment a, Media media) async {
    if (current.value == a.id) {
      // nothing to pause while it is still being fetched: the player would
      // report playing with nothing loaded
      if (loading.value == null) await player.playOrPause();
      return;
    }
    final turn = ++_turn;
    if (a.kind == MediaKind.video) video; // the picture needs its surface first
    // what played before stops now, not when the new one has arrived
    if (player.state.playing) unawaited(player.pause());
    current.value = a.id;
    loading.value = 0;
    try {
      final String source;
      if (a.pending) {
        source = a.local;
      } else if (files.hasFiles) {
        source = (await media.file(
          a,
          onProgress: (f) {
            if (turn == _turn) loading.value = f;
          },
        ))!;
      } else {
        source = (await media.url(a)).toString();
      }
      if (turn != _turn) return; // another started meanwhile
      await player.open(mk.Media(source));
    } catch (_) {
      if (turn == _turn) {
        current.value = null;
        showMessage('Could not play ${a.name}');
      }
    } finally {
      if (turn == _turn) loading.value = null;
    }
  }

  /// Jumps [seconds] forward (or back), never past either end.
  Future<void> skip(int seconds) async {
    final to = player.state.position + Duration(seconds: seconds);
    final end = player.state.duration;
    await player.seek(to < Duration.zero ? Duration.zero : (to > end ? end : to));
  }

  /// Stops and unloads whatever is playing (the mini player's close).
  Future<void> stop() async {
    _turn++;
    current.value = null;
    loading.value = null;
    await player.stop();
  }

  void dispose() {
    unawaited(player.dispose());
    current.dispose();
    loading.dispose();
  }
}

final mediaDeckProvider = Provider<MediaDeck>((ref) {
  final deck = MediaDeck();
  ref.onDispose(deck.dispose);
  return deck;
});

String formatDuration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// Position, a slider, and length, for any player. What has played is a
/// wavy line that travels while it plays, and settles flat when playback
/// pauses or the handle is dragged (expressive.dart's [WavyTrackShape]).
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.player, this.color});
  final mk.Player player;
  final Color? color;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> with TickerProviderStateMixin {
  double? _dragging;

  // one wavelength a second; the amplitude comes and goes
  late final _wave = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  late final _swell = AnimationController(vsync: this, duration: Durations.medium2);
  StreamSubscription<bool>? _playing;

  @override
  void initState() {
    super.initState();
    _move(widget.player.state.playing);
    _playing = widget.player.stream.playing.listen(_move);
  }

  void _move(bool playing) {
    if (!mounted) return;
    if (playing && _dragging == null) {
      unawaited(_wave.repeat());
      unawaited(_swell.forward());
    } else {
      unawaited(
        _swell.reverse().whenComplete(() {
          if (mounted && _swell.isDismissed) _wave.stop();
        }),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_playing?.cancel());
    _wave.dispose();
    _swell.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: widget.color);
    return StreamBuilder(
      stream: p.stream.position,
      initialData: p.state.position,
      builder: (context, pos) {
        final total = p.state.duration;
        final ms = total.inMilliseconds.toDouble();
        final at = _dragging ?? (ms == 0 ? 0.0 : (pos.data!.inMilliseconds / ms).clamp(0.0, 1.0));
        return Row(
          children: [
            Text(formatDuration(Duration(milliseconds: (at * ms).round())), style: style),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([_wave, _swell]),
                builder: (context, _) => SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    trackGap: 6,
                    thumbSize: const WidgetStatePropertyAll(Size(4, 28)),
                    trackShape: WavyTrackShape(phase: _wave.value, swell: Curves.easeInOut.transform(_swell.value)),
                  ),
                  child: Slider(
                    value: at,
                    onChangeStart: (_) {
                      _dragging = at;
                      _move(false);
                    },
                    onChanged: ms == 0 ? null : (v) => setState(() => _dragging = v),
                    onChangeEnd: (v) async {
                      await p.seek(Duration(milliseconds: (v * ms).round()));
                      if (!mounted) return;
                      setState(() => _dragging = null);
                      _move(p.state.playing);
                    },
                  ),
                ),
              ),
            ),
            Text(formatDuration(total), style: style),
          ],
        );
      },
    );
  }
}

/// Plays or pauses [attachment] on the app's one player; it also starts it.
void togglePlayback(WidgetRef ref, Attachment attachment) {
  final media = ref.read(mediaProvider);
  if (media != null) unawaited(ref.read(mediaDeckProvider).toggle(attachment, media));
}

/// Builds with whether [attachment] is the one on the player, and playing.
class PlaybackBuilder extends ConsumerWidget {
  const PlaybackBuilder({super.key, required this.attachment, required this.builder});
  final Attachment attachment;
  final Widget Function(BuildContext context, MediaDeck deck, bool mine, bool playing) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deck = ref.watch(mediaDeckProvider);
    return ValueListenableBuilder(
      valueListenable: deck.current,
      builder: (context, current, _) => StreamBuilder(
        stream: deck.player.stream.playing,
        initialData: deck.player.state.playing,
        builder: (context, playing) {
          final mine = current == attachment.id;
          return builder(context, deck, mine, mine && (playing.data ?? false));
        },
      ),
    );
  }
}

/// A full player's seek bar, 48dp tall: the fetch's progress while the file
/// is on its way, then the seek bar; an empty space while another file is
/// on the player.
class DeckSeekBar extends StatelessWidget {
  const DeckSeekBar({super.key, required this.deck, required this.mine, this.color});
  final MediaDeck deck;
  final bool mine;
  final Color? color;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: deck.loading,
    builder: (context, loading, _) => !mine
        ? const SizedBox(height: 48)
        : loading != null
        ? SizedBox(
            height: 48,
            child: Center(child: WavyProgress(value: loading == 0 ? null : loading)),
          )
        : SeekBar(player: deck.player, color: color),
  );
}
