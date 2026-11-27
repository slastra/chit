import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'note_routes.dart';
import 'media_player.dart';
import 'expressive.dart';

/// The mini player's height, without its margin.
const _miniHeight = 64.0;
const _miniMargin = 8.0;

/// The audio on the player, with its note: null when nothing is loaded or
/// what is loaded is a video (that plays where it is shown).
({Attachment audio, Note? note})? _nowPlaying(Library lib, String? id) {
  if (id == null) return null;
  for (final MapEntry(key: noteId, value: list) in lib.attachments.entries) {
    for (final a in list) {
      if (a.id == id) {
        if (a.kind != MediaKind.audio) return null;
        return (audio: a, note: lib.notes.where((n) => n.id == noteId).firstOrNull);
      }
    }
  }
  return null;
}

/// Whether the full player is up (the mini player steps aside for it).
final _expanded = ValueNotifier(false);

/// Docks the mini player along the bottom of the app while audio is loaded,
/// and moves everything above it up by its height (as bottom padding, so
/// pages, FABs and snackbars all clear it).
class AudioDock extends ConsumerWidget {
  const AudioDock({super.key, required this.navigatorKey, required this.child});
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deck = ref.watch(mediaDeckProvider);
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    return ValueListenableBuilder(
      valueListenable: deck.current,
      builder: (context, current, _) => ValueListenableBuilder(
        valueListenable: _expanded,
        builder: (context, expanded, _) {
          final playing = expanded ? null : _nowPlaying(lib, current);
          final mq = MediaQuery.of(context);
          final room = playing == null ? 0.0 : _miniHeight + _miniMargin;
          return Stack(
            children: [
              MediaQuery(
                data: mq.copyWith(
                  padding: mq.padding.copyWith(bottom: mq.padding.bottom + room),
                  viewPadding: mq.viewPadding.copyWith(bottom: mq.viewPadding.bottom + room),
                ),
                child: child,
              ),
              if (playing != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: mq.padding.bottom + _miniMargin,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: _miniMargin),
                        // its own overlay: the bar lives above the navigator's,
                        // and its buttons' tooltips need one
                        child: SizedBox(
                          height: _miniHeight,
                          child: Overlay(
                            key: ValueKey(playing.audio.id),
                            clipBehavior: Clip.none,
                            initialEntries: [
                              OverlayEntry(
                                builder: (_) => MiniPlayer(
                                  audio: playing.audio,
                                  note: playing.note,
                                  onExpand: () {
                                    final nav = navigatorKey.currentContext;
                                    if (nav != null) unawaited(showAudioPlayer(nav, playing.audio));
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
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

/// The now-playing bar: play or pause, the file and its note, close; a
/// progress line along its foot. A tap anywhere else opens the full player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, required this.audio, required this.note, required this.onExpand});
  final Attachment audio;
  final Note? note;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final deck = ref.watch(mediaDeckProvider);
    // its own Material: the bar sits above the navigator, outside any page
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 3,
      shadowColor: scheme.shadow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onExpand,
        child: SizedBox(
          height: _miniHeight,
          child: Stack(
            children: [
              Row(
                children: [
                  const SizedBox(width: 8),
                  PlaybackBuilder(
                    attachment: audio,
                    builder: (context, deck, mine, playing) => IconButton.filledTonal(
                      tooltip: playing ? 'Pause' : 'Play',
                      onPressed: () => togglePlayback(ref, audio),
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          audio.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface),
                        ),
                        if (note case final n? when n.label.isNotEmpty)
                          Text(
                            n.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Stop', onPressed: () => unawaited(deck.stop()), icon: const Icon(Icons.close)),
                  const SizedBox(width: 4),
                ],
              ),
              // along the straight part of the foot, clear of the corners
              Positioned(
                left: 16,
                right: 16,
                bottom: 0,
                child: StreamBuilder(
                  stream: deck.player.stream.position,
                  initialData: deck.player.state.position,
                  builder: (context, pos) {
                    final ms = deck.player.state.duration.inMilliseconds;
                    return LinearProgressIndicator(
                      value: ms == 0 ? 0 : ((pos.data?.inMilliseconds ?? 0) / ms).clamp(0.0, 1.0),
                      minHeight: 2,
                      backgroundColor: Colors.transparent,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full player, as a bottom sheet over everything: the file's mark and
/// name, its note (which it opens), the seek bar, back 10, play, forward
/// 10, and playback speed. Starts [audio] if it isn't the one loaded.
Future<void> showAudioPlayer(BuildContext context, Attachment audio) async {
  final container = ProviderScope.containerOf(context);
  final deck = container.read(mediaDeckProvider);
  final media = container.read(mediaProvider);
  if (deck.current.value != audio.id && media != null) unawaited(deck.toggle(audio, media));
  _expanded.value = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => _FullPlayer(audio: audio),
    );
  } finally {
    _expanded.value = false;
  }
}

class _FullPlayer extends ConsumerWidget {
  const _FullPlayer({required this.audio});
  final Attachment audio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final note = lib.notes.where((n) => n.id == audio.note).firstOrNull;
    Future<void> skip(MediaDeck deck, int seconds) async {
      final p = deck.player;
      final to = p.state.position + Duration(seconds: seconds);
      await p.seek(to < Duration.zero ? Duration.zero : (to > p.state.duration ? p.state.duration : to));
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.space): () => togglePlayback(ref, audio)},
      child: Focus(
        autofocus: true,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: PlaybackBuilder(
                  attachment: audio,
                  builder: (context, deck, mine, playing) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DecoratedBox(
                        decoration: ShapeDecoration(
                          color: scheme.primaryContainer,
                          shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
                        ),
                        child: SizedBox.square(
                          dimension: 144,
                          child: Icon(kindIcon(audio), size: 56, color: scheme.onPrimaryContainer),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        audio.name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                      if (note != null && note.label.isNotEmpty)
                        // the note it belongs to, one tap away
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            unawaited(openNote(context, '/note/${note.id}'));
                          },
                          child: Text(note.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      const SizedBox(height: 16),
                      ValueListenableBuilder(
                        valueListenable: deck.loading,
                        builder: (context, loading, _) => mine && loading != null
                            ? SizedBox(
                                height: 48,
                                child: Center(child: LinearProgressIndicator(value: loading == 0 ? null : loading)),
                              )
                            : (mine ? SeekBar(player: deck.player) : const SizedBox(height: 48)),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 24,
                        children: [
                          IconButton(
                            tooltip: 'Back 10 seconds',
                            style: iconButtonSize(56, 32),
                            onPressed: mine ? () => skip(deck, -10) : null,
                            icon: const Icon(Icons.replay_10_rounded),
                          ),
                          IconButton.filled(
                            tooltip: playing ? 'Pause' : 'Play',
                            style: iconButtonSize(96, 32),
                            onPressed: () => togglePlayback(ref, audio),
                            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                          ),
                          IconButton(
                            tooltip: 'Forward 10 seconds',
                            style: iconButtonSize(56, 32),
                            onPressed: mine ? () => skip(deck, 10) : null,
                            icon: const Icon(Icons.forward_10_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _Speed(deck: deck),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Playback speed as a connected button group: voice memos go faster at 1.5x.
class _Speed extends StatelessWidget {
  const _Speed({required this.deck});
  final MediaDeck deck;

  static const _rates = [1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: deck.player.stream.rate,
    initialData: deck.player.state.rate,
    builder: (context, rate) {
      final now = _rates.reduce((a, b) => ((rate.data ?? 1) - a).abs() <= ((rate.data ?? 1) - b).abs() ? a : b);
      return ConnectedButtonGroup<double>(
        values: _rates,
        selected: now,
        label: (r) => '${r == r.roundToDouble() ? r.toInt() : r}×',
        tooltip: (r) => '${r == r.roundToDouble() ? r.toInt() : r} times speed',
        onSelected: (r) => unawaited(deck.player.setRate(r)),
      );
    },
  );
}
