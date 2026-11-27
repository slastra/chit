import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:record/record.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../state/providers.dart';
import 'audio_player.dart';
import 'note_routes.dart';
import 'create.dart' show newNoteDefaults;
import 'expressive.dart';
import 'feedback.dart';
import 'home_page.dart' show isExpanded;

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

// ---- showing -----------------------------------------------------------------

/// An attachment's image: its local copy while it uploads, else a download
/// (a thumbnail when [thumb] is given: "320x320" crops square, "1080x0"
/// keeps the aspect). A tonal placeholder holds the place meanwhile.
class AttachmentImage extends ConsumerStatefulWidget {
  const AttachmentImage(
    this.attachment, {
    super.key,
    this.thumb,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholderHeight,
  });

  final Attachment attachment;
  final String? thumb;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// The placeholder's height before the image's own size is known.
  final double? placeholderHeight;

  @override
  ConsumerState<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends ConsumerState<AttachmentImage> {
  Future<ImageProvider?>? _image;
  String _key = '';

  Future<ImageProvider?> _resolve(Media media) async {
    final a = widget.attachment;
    if (a.pending) {
      if (files.hasFiles) return a.local.isEmpty ? null : files.fileImage(a.local);
      final b = await media.pendingBytes(a);
      return b == null ? null : MemoryImage(b);
    }
    if (files.hasFiles) {
      final p = await media.file(a, thumb: widget.thumb);
      return p == null ? null : files.fileImage(p);
    }
    return NetworkImage((await media.url(a, thumb: widget.thumb)).toString());
  }

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaProvider);
    final a = widget.attachment;
    final key = '${a.id}/${a.pending}/${widget.thumb}';
    if (media != null && key != _key) {
      _key = key;
      _image = _resolve(media);
    }
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder({bool broken = false}) => Container(
      width: widget.width,
      height: widget.height ?? widget.placeholderHeight,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: broken ? Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant) : null,
    );
    return FutureBuilder(
      future: _image,
      builder: (context, snap) {
        final image = snap.data;
        if (snap.hasError) return placeholder(broken: true);
        if (image == null) return placeholder();
        return Image(
          image: image,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
          semanticLabel: a.name,
          errorBuilder: (_, _, _) => placeholder(broken: true),
        );
      },
    );
  }
}

/// A file still uploading: a ring that fills as it goes, or a waiting mark
/// while it cannot start (offline, or its note is still on its way).
class UploadMark extends ConsumerWidget {
  const UploadMark(this.attachment, {super.key, this.size = 20, this.onImage = false});
  final Attachment attachment;
  final double size;

  /// Drawn over an image: on a scrim, so it reads on any picture.
  final bool onImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!attachment.pending) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final progress = ref.watch(uploadProgressProvider).value?[attachment.id];
    final ink = onImage ? Colors.white : scheme.primary;
    final mark = progress == null
        ? Icon(Icons.cloud_upload_outlined, size: size, color: onImage ? Colors.white : scheme.onSurfaceVariant)
        : SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator(value: progress, strokeWidth: 2.5, color: ink),
          );
    final label = progress == null ? 'Waiting to upload' : 'Uploading ${(progress * 100).round()}%';
    return Tooltip(
      message: label,
      child: onImage
          ? DecoratedBox(
              decoration: const BoxDecoration(color: Color(0x66000000), shape: BoxShape.circle),
              child: Padding(padding: const EdgeInsets.all(6), child: mark),
            )
          : mark,
    );
  }
}

/// What a file is, in a word, for supporting text and screen readers.
String kindLabel(Attachment a) => switch (a.kind) {
  MediaKind.image => 'Image',
  MediaKind.video => 'Video',
  MediaKind.audio => 'Audio',
  MediaKind.pdf => 'PDF',
  MediaKind.other => a.type.isEmpty ? 'File' : a.type,
};

IconData kindIcon(Attachment a) => switch (a.kind) {
  MediaKind.image => Icons.image_outlined,
  MediaKind.video => Icons.movie_outlined,
  MediaKind.audio => a.name.startsWith('Voice memo') ? Icons.mic_none : Icons.music_note_outlined,
  MediaKind.pdf => Icons.picture_as_pdf_outlined,
  MediaKind.other => Icons.insert_drive_file_outlined,
};

void openAttachment(BuildContext context, Attachment a) => a.kind == MediaKind.audio
    ? unawaited(showAudioPlayer(context, a))
    : unawaited(context.push('/note/${a.note}/file/${a.id}'));

/// A picture that flies between its place in a note and the viewer (a
/// shared element): on the way it turns from the tile's crop into the
/// whole picture, its corners squaring off.
Widget pictureHero(Attachment a, {required Widget child}) => Hero(
  tag: 'picture/${a.id}',
  flightShuttleBuilder: (context, animation, direction, from, to) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      // 0 at the tile, 1 in the viewer, either way round
      final t = Curves.easeInOut.transform(animation.value);
      Widget picture(BoxFit fit) =>
          AttachmentImage(a, thumb: '1080x0', fit: fit, width: double.infinity, height: double.infinity);
      return ClipRRect(
        borderRadius: BorderRadius.circular(28 * (1 - t)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(opacity: 1 - t, child: picture(BoxFit.cover)),
            Opacity(opacity: t, child: picture(BoxFit.contain)),
          ],
        ),
      );
    },
  ),
  child: child,
);

/// A note's images: one whole, at its own shape; several as Material's
/// multi-browse carousel. Each opens the viewer.
class NoteImages extends StatelessWidget {
  const NoteImages({super.key, required this.images, this.maxHeight = 480, this.carouselHeight = 240, this.gap = 4});
  final List<Attachment> images;
  final double maxHeight;
  final double carouselHeight;
  final double gap;

  @override
  Widget build(BuildContext context) {
    Widget tile(Attachment a, {required String thumb, double? width, double? height}) => Semantics(
      button: true,
      label: 'Open ${a.name}',
      child: InkWell(
        onTap: () => openAttachment(context, a),
        child: Stack(
          children: [
            pictureHero(
              a,
              child: AttachmentImage(a, thumb: thumb, width: width, height: height, placeholderHeight: 200),
            ),
            Positioned(right: 8, bottom: 8, child: UploadMark(a, onImage: true)),
          ],
        ),
      ),
    );
    final theme = Theme.of(context);
    if (images.length == 1) {
      // one picture: whole, in the card's corners
      final card = theme.cardTheme.shape;
      return ClipRRect(
        borderRadius: card is RoundedRectangleBorder
            ? card.borderRadius.resolve(Directionality.of(context))
            : BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SizedBox(
            width: double.infinity,
            child: tile(images.first, thumb: '1080x0', width: double.infinity),
          ),
        ),
      );
    }
    // several: Material's multi-browse carousel, a large picture, a
    // medium and a small one, each growing as it comes to the front
    return SizedBox(
      height: carouselHeight,
      child: ScrollConfiguration(
        // a mouse drags it too (a wheel only scrolls the page)
        behavior: ScrollConfiguration.of(context)
            .copyWith(dragDevices: {...PointerDeviceKind.values}, scrollbars: false),
        child: CarouselView.weighted(
          flexWeights: images.length == 2 ? const [3, 2] : const [3, 2, 1],
          itemSnapping: true,
          padding: EdgeInsets.symmetric(horizontal: gap),
          // the carousel's extra-large corner, from the theme's shape scale
          shape: theme.dialogTheme.shape ?? RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          onTap: (i) => openAttachment(context, images[i]),
          children: [
            for (final a in images)
              Semantics(
                image: true,
                label: a.name,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    pictureHero(
                      a,
                      child: AttachmentImage(a, thumb: '1080x0', width: double.infinity, height: carouselHeight),
                    ),
                    Positioned(right: 12, bottom: 12, child: UploadMark(a, onImage: true)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A PDF's first page, small, for its row.
class PdfFirstPage extends ConsumerStatefulWidget {
  const PdfFirstPage(this.attachment, {super.key});
  final Attachment attachment;

  @override
  ConsumerState<PdfFirstPage> createState() => _PdfFirstPageState();
}

class _PdfFirstPageState extends ConsumerState<PdfFirstPage> {
  // fetched once, not on every rebuild of the row (an upload's progress
  // rebuilds it many times a second)
  Future<String?>? _file;
  Media? _media;

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaProvider);
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(Icons.picture_as_pdf_outlined, color: scheme.onSecondaryContainer);
    Widget frame(Widget child) => ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(width: 40, height: 52, color: scheme.secondaryContainer, child: child),
    );
    if (media == null || !files.hasFiles) return frame(fallback);
    if (media != _media) {
      _media = media;
      _file = media.file(widget.attachment);
    }
    return frame(
      FutureBuilder(
        future: _file,
        builder: (context, snap) => snap.data == null
            ? fallback
            : PdfDocumentViewBuilder.file(
                snap.data!,
                builder: (context, doc) =>
                    doc == null ? fallback : PdfPageView(document: doc, pageNumber: 1, alignment: Alignment.topCenter),
              ),
      ),
    );
  }
}

/// A file that is not an image: a list row (Material's list item) with its
/// kind, size and upload state; audio plays right in the row.
class FileRow extends ConsumerWidget {
  const FileRow({super.key, required this.attachment, required this.onRemove});
  final Attachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = attachment;
    final scheme = Theme.of(context).colorScheme;
    final progress = ref.watch(uploadProgressProvider).value?[a.id];
    final detail = a.pending
        ? (progress == null ? 'Waiting to upload' : 'Uploading ${(progress * 100).round()}%')
        : '${formatSize(a.size)} · ${kindLabel(a)}';
    final Widget leading = switch (a.kind) {
      MediaKind.pdf => PdfFirstPage(a),
      MediaKind.audio => AudioButton(a),
      _ => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
        child: Icon(
          a.kind == MediaKind.video ? Icons.play_arrow_rounded : kindIcon(a),
          color: scheme.onSecondaryContainer,
        ),
      ),
    };
    final remove = onRemove == null
        ? null
        : IconButton(tooltip: 'Remove ${a.name}', icon: const Icon(Icons.close), onPressed: onRemove);
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 4),
          // one width for every kind, so the names line up
          leading: SizedBox(width: 48, child: Center(child: leading)),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(detail),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [UploadMark(a), ?remove]),
          onTap: () => openAttachment(context, a),
        ),
        if (a.kind == MediaKind.audio) AudioProgress(a),
      ],
    );
  }
}

// ---- audio, inline -------------------------------------------------------------

/// A media_kit player for this app. Its libmpv setup (no Lua scripts,
/// stereo output) lives in the patched copy: third_party/media_kit/CHIT.md.
mk.Player newPlayer() => mk.Player();

/// The app's one player, audio and video alike: starting one stops
/// whatever played before, and a video started on a card carries on full
/// screen.
final class MediaDeck {
  MediaDeck() : player = newPlayer();

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

/// Play and pause, in a row's leading slot.
class AudioButton extends ConsumerWidget {
  const AudioButton(this.attachment, {super.key});
  final Attachment attachment;

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
          final on = mine && (playing.data ?? false);
          return IconButton.filledTonal(
            tooltip: on ? 'Pause' : 'Play ${attachment.name}',
            icon: Icon(on ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: () {
              final media = ref.read(mediaProvider);
              if (media != null) unawaited(deck.toggle(attachment, media));
            },
          );
        },
      ),
    );
  }
}

String formatDuration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// The playing row's seek bar and times; nothing for the rows not playing.
class AudioProgress extends ConsumerWidget {
  const AudioProgress(this.attachment, {super.key});
  final Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deck = ref.watch(mediaDeckProvider);
    return ValueListenableBuilder(
      valueListenable: deck.current,
      builder: (context, current, _) {
        if (current != attachment.id) return const SizedBox.shrink();
        return ValueListenableBuilder(
          valueListenable: deck.loading,
          builder: (context, loading, _) => loading != null
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(72, 0, 24, 12),
                  child: WavyProgress(value: loading == 0 ? null : loading),
                )
              : Padding(
                  padding: const EdgeInsets.only(left: 56, right: 8),
                  child: SeekBar(player: deck.player),
                ),
        );
      },
    );
  }
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

// ---- adding --------------------------------------------------------------------

/// Where new files come from.
enum AddSource {
  media('Photo or video', Icons.photo_library_outlined),
  photo('Take photo', Icons.photo_camera_outlined),
  video('Record video', Icons.videocam_outlined),
  memo('Voice memo', Icons.mic_none),
  file('File', Icons.attach_file);

  const AddSource(this.label, this.icon);
  final String label;
  final IconData icon;

  /// The camera is Android's (the system camera, through image_picker).
  bool get available => switch (this) {
    photo || video => _android,
    _ => true,
  };

  static List<AddSource> get offered => values.where((s) => s.available).toList();
}

Future<NewFile> _fromXFile(XFile f) async =>
    (name: f.name, size: await f.length(), path: kIsWeb ? null : f.path, bytes: kIsWeb ? await f.readAsBytes() : null);

Future<NewFile> _fromPicked(PlatformFile f) async => (
  name: f.name,
  size: await f.length() ?? 0,
  path: kIsWeb ? null : f.path,
  bytes: kIsWeb || f.path == null ? await f.readAsBytes() : null,
);

/// Asks for files from [source]; empty when the user backs out.
Future<List<NewFile>> pickFrom(BuildContext context, AddSource source) async {
  final images = ImagePicker();
  switch (source) {
    case AddSource.media:
      if (_android) return Future.wait((await images.pickMultipleMedia()).map(_fromXFile));
      return Future.wait((await FilePicker.pickFiles(type: FileType.media)).map(_fromPicked));
    case AddSource.photo:
      final f = await images.pickImage(source: ImageSource.camera);
      return f == null ? const [] : [await _fromXFile(f)];
    case AddSource.video:
      final f = await images.pickVideo(source: ImageSource.camera);
      return f == null ? const [] : [await _fromXFile(f)];
    case AddSource.memo:
      final memo = await recordVoiceMemo(context);
      return memo == null ? const [] : [memo];
    case AddSource.file:
      return Future.wait((await FilePicker.pickFiles()).map(_fromPicked));
  }
}

/// The Add button for the note's toolbar: the ways to add a file, as a menu
/// on expanded windows and a bottom sheet on compact ones (like the palette).
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.onPick});
  final ValueChanged<AddSource> onPick;

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.add_box_outlined);
    if (isExpanded(context)) {
      return MenuAnchor(
        builder: (context, ctl, _) =>
            IconButton(tooltip: 'Add', icon: icon, onPressed: () => ctl.isOpen ? ctl.close() : ctl.open()),
        menuChildren: [
          for (final s in AddSource.offered)
            MenuItemButton(leadingIcon: Icon(s.icon), onPressed: () => onPick(s), child: Text(s.label)),
        ],
      );
    }
    return IconButton(
      tooltip: 'Add',
      icon: icon,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedList(
                children: [
                  for (final s in AddSource.offered)
                    ListTile(
                      leading: Icon(s.icon),
                      title: Text(s.label),
                      onTap: () {
                        Navigator.pop(sheet);
                        onPick(s);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Queues [picked] on [note] and says which files were too large.
Future<void> attachTo(BuildContext context, String note, List<NewFile> picked) async {
  if (picked.isEmpty) return;
  final c = ProviderScope.containerOf(context);
  final tooBig = await attachFiles(c.read(replicaProvider), c.read(engineProvider), note, picked);
  if (tooBig.isNotEmpty) {
    showMessage(
      tooBig.length == 1
          ? '${tooBig.first} is over the ${maxAttachmentSize >> 20} MB limit'
          : '${tooBig.length} files are over the ${maxAttachmentSize >> 20} MB limit',
    );
  }
}

/// A new note holding [picked], opened.
Future<void> newNoteWithFiles(BuildContext context, List<NewFile> picked) async {
  if (picked.isEmpty) return;
  final engine = ProviderScope.containerOf(context).read(engineProvider);
  if (engine == null) return;
  final id = randomId();
  final label = newNoteDefaults.value.label;
  await engine.edit([
    engine.op(Collections.notes, id, 'kind', 'text'),
    if (label != null) engine.op(Collections.noteState, id, 'labels', [label]),
  ]);
  if (!context.mounted) return;
  await attachTo(context, id, picked);
  if (context.mounted) await openNote(context, '/note/$id');
}

// ---- voice memos ---------------------------------------------------------------

/// Records a voice memo: a dialog on expanded windows, a bottom sheet on
/// compact ones. Null when cancelled or the microphone is refused.
Future<NewFile?> recordVoiceMemo(BuildContext context) {
  const recorder = _MemoRecorder();
  return isExpanded(context)
      ? showDialog<NewFile>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Dialog(child: recorder),
        )
      : showModalBottomSheet<NewFile>(
          context: context,
          isDismissible: false,
          enableDrag: false,
          builder: (_) => const SafeArea(child: recorder),
        );
}

class _MemoRecorder extends StatefulWidget {
  const _MemoRecorder();

  @override
  State<_MemoRecorder> createState() => _MemoRecorderState();
}

class _MemoRecorderState extends State<_MemoRecorder> {
  final _rec = AudioRecorder();
  final _started = DateTime.now();
  Timer? _tick;
  StreamSubscription<Amplitude>? _levels;
  double _level = 0;
  String _ext = 'm4a';
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'chit needs the microphone to record.');
        return;
      }
      // AAC in m4a where the platform has it; Opus, then WAV, otherwise
      var encoder = AudioEncoder.aacLc;
      for (final (e, ext) in [(AudioEncoder.aacLc, 'm4a'), (AudioEncoder.opus, 'ogg'), (AudioEncoder.wav, 'wav')]) {
        if (await _rec.isEncoderSupported(e)) {
          encoder = e;
          _ext = ext;
          break;
        }
      }
      await _rec.start(RecordConfig(encoder: encoder, numChannels: 1), path: await files.recordingPath(_ext));
      _levels = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
        // dBFS to 0..1 over a 50 dB range
        if (mounted) setState(() => _level = ((a.current + 50) / 50).clamp(0.0, 1.0));
      });
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't start recording.");
    }
  }

  Future<void> _finish({required bool keep}) async {
    setState(() => _saving = keep);
    _tick?.cancel();
    await _levels?.cancel();
    final where = await _rec.stop();
    if (!mounted) return;
    if (!keep || where == null || where.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final now = DateTime.now();
    final name = 'Voice memo, ${DateFormatLite.stamp(now)}.$_ext';
    if (kIsWeb) {
      // the web recorder hands back a blob URL
      final bytes = (await http.get(Uri.parse(where))).bodyBytes;
      if (mounted) Navigator.pop(context, (name: name, size: bytes.length, path: null, bytes: bytes) as NewFile);
      return;
    }
    final size = await files.sizeOf(where);
    if (mounted) Navigator.pop(context, (name: name, size: size, path: where, bytes: null) as NewFile);
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_levels?.cancel());
    unawaited(_rec.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final elapsed = DateTime.now().difference(_started);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(_error == null ? Icons.mic : Icons.mic_off_outlined, color: scheme.secondary, size: 24),
            const SizedBox(height: 16),
            Text(
              _error == null ? 'Recording' : "Can't record",
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            if (_error case final e?)
              Text(
                e,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            else ...[
              Text(
                formatDuration(elapsed),
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 16),
              Semantics(
                label: 'Input level',
                child: LinearProgressIndicator(value: _level, minHeight: 8, borderRadius: BorderRadius.circular(4)),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => _finish(keep: false),
                  child: Text(_error == null ? 'Cancel' : 'Close'),
                ),
                // a dialog's actions are text buttons (Material's dialog spec)
                if (_error == null)
                  TextButton(onPressed: _saving ? null : () => _finish(keep: true), child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Nov 26 10:45", without pulling a locale into a file name.
abstract final class DateFormatLite {
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String stamp(DateTime d) =>
      '${_months[d.month - 1]} ${d.day} ${d.hour.toString().padLeft(2, '0')}.${d.minute.toString().padLeft(2, '0')}';
}
