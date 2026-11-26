import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'feedback.dart';
import 'app.dart' show themeSpecProvider;
import 'theme.dart';

/// One attachment, full screen on a dark surface whatever the theme (media
/// reads best on dark): images paged and zoomable, PDFs, video and audio
/// with Material controls, anything else offered to save.
class ViewerPage extends ConsumerStatefulWidget {
  const ViewerPage({super.key, required this.noteId, required this.attachmentId});
  final String noteId;
  final String attachmentId;

  @override
  ConsumerState<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends ConsumerState<ViewerPage> {
  late String _current = widget.attachmentId;
  PageController? _pages;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  Future<void> _save(Attachment a) async {
    final media = ref.read(mediaProvider);
    if (media == null) return;
    try {
      final path = await media.file(a);
      final bytes = path != null
          ? await files.readBytes(path)
          : await (await media.api.download(await media.url(a))).fold<List<int>>([], (all, c) => all..addAll(c));
      await FilePicker.saveFile(fileName: a.name, bytes: Uint8List.fromList(bytes), mimeType: a.type);
    } catch (e) {
      showMessage("Couldn't save ${a.name}");
    }
  }

  void _delete(Attachment a) {
    final engine = ref.read(engineProvider);
    if (engine == null) return;
    if (a.pending) {
      unawaited(ref.read(replicaProvider).dropUpload(a.id));
    } else {
      unawaited(engine.edit([engine.op(Collections.attachments, a.id, 'deleted', true)]));
      showUndo('File removed', () => engine.edit([engine.op(Collections.attachments, a.id, 'deleted', false)]));
    }
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider).value ?? Library.empty;
    final all = lib.attachments[widget.noteId] ?? const <Attachment>[];
    final a = all.where((x) => x.id == _current).firstOrNull;
    if (a == null) {
      if (ref.watch(libraryProvider).hasValue) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.pop();
        });
      }
      return const Scaffold(backgroundColor: Colors.black);
    }
    final app = Theme.of(context).colorScheme;
    final dark = themeFor(
      ColorScheme.fromSeed(
        seedColor: app.primary,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
      ).copyWith(surface: Colors.black, onSurface: Colors.white),
      ref.watch(themeSpecProvider).value,
    );
    final images = all.where((x) => x.isImage).toList();

    final Widget body = switch (a.kind) {
      MediaKind.image => _Images(
        images: images,
        controller: _pages ??= PageController(initialPage: images.indexOf(a).clamp(0, images.length)),
        onPage: (i) => setState(() => _current = images[i].id),
      ),
      MediaKind.pdf => _Pdf(a),
      MediaKind.video => _Video(a),
      MediaKind.audio => _Audio(a),
      MediaKind.other => _Other(a, onSave: () => _save(a)),
    };

    return Theme(
      data: dark,
      child: CallbackShortcuts(
        // on the page's own focus, so they work whatever has focus inside
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => context.pop(),
          if (a.kind == MediaKind.image && _pages != null) ...{
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _pages!.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _pages!.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic),
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black,
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.4),
              leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => context.pop()),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    a.pending ? 'Waiting to upload' : '${formatSize(a.size)} · ${kindLabel(a)}',
                    style: dark.textTheme.labelMedium?.copyWith(color: dark.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              actions: [
                if (!a.pending)
                  IconButton(
                    tooltip: 'Save a copy',
                    icon: const Icon(Icons.download_outlined),
                    onPressed: () => _save(a),
                  ),
                IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(a)),
                const SizedBox(width: 4),
              ],
            ),
            body: SafeArea(top: a.kind != MediaKind.image, child: body),
          ),
        ),
      ),
    );
  }
}

/// A file fetched for viewing (native platforms download to the cache; the
/// web streams by URL), with progress while it comes.
class _Fetched extends ConsumerStatefulWidget {
  const _Fetched(this.attachment, {required this.builder});
  final Attachment attachment;

  /// Gets a local path, or on the web a URL.
  final Widget Function(BuildContext context, String source) builder;

  @override
  ConsumerState<_Fetched> createState() => _FetchedState();
}

class _FetchedState extends ConsumerState<_Fetched> {
  Future<String>? _source;
  double? _progress;

  Future<String> _fetch() async {
    final media = ref.read(mediaProvider)!;
    final a = widget.attachment;
    if (files.hasFiles) {
      final p = await media.file(a, onProgress: (f) => mounted ? setState(() => _progress = f) : null);
      if (p == null) throw StateError('no file');
      return p;
    }
    return (await media.url(a)).toString();
  }

  @override
  Widget build(BuildContext context) {
    _source ??= ref.read(mediaProvider) == null ? null : _fetch();
    return FutureBuilder(
      future: _source,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text("Couldn't load ${widget.attachment.name}", style: const TextStyle(color: Colors.white70)),
          );
        }
        if (snap.data case final source?) return widget.builder(context, source);
        return Center(
          child: SizedBox(width: 200, child: LinearProgressIndicator(value: _progress == 0 ? null : _progress)),
        );
      },
    );
  }
}

class _Images extends StatelessWidget {
  const _Images({required this.images, required this.controller, required this.onPage});
  final List<Attachment> images;
  final PageController controller;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => PageView.builder(
    controller: controller,
    itemCount: images.length,
    onPageChanged: onPage,
    itemBuilder: (context, i) => InteractiveViewer(
      maxScale: 6,
      child: Center(
        child: AttachmentImage(images[i], fit: BoxFit.contain, width: double.infinity, height: double.infinity),
      ),
    ),
  );
}

class _Pdf extends ConsumerWidget {
  const _Pdf(this.attachment);
  final Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ColoredBox(
    color: const Color(0xFF1B1B1F),
    child: _Fetched(
      attachment,
      builder: (context, source) => files.hasFiles ? PdfViewer.file(source) : PdfViewer.uri(Uri.parse(source)),
    ),
  );
}

class _Video extends StatefulWidget {
  const _Video(this.attachment);
  final Attachment attachment;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  late final _player = newPlayer();
  late final _controller = VideoController(_player);
  String? _opened;

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Fetched(
    widget.attachment,
    builder: (context, source) {
      if (_opened != source) {
        _opened = source;
        unawaited(_player.open(mk.Media(source)));
      }
      return CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.space): _player.playOrPause},
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _player.playOrPause,
                child: Video(controller: _controller, controls: NoVideoControls),
              ),
            ),
            Positioned(left: 0, right: 0, bottom: 0, child: _Controls(player: _player)),
          ],
        ),
      );
    },
  );
}

/// Play or pause and a seek bar, on a scrim along the bottom.
class _Controls extends StatelessWidget {
  const _Controls({required this.player});
  final mk.Player player;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00000000), Color(0xAA000000)],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
      child: Row(
        children: [
          StreamBuilder(
            stream: player.stream.playing,
            initialData: player.state.playing,
            builder: (context, playing) => IconButton.filledTonal(
              tooltip: (playing.data ?? false) ? 'Pause' : 'Play',
              icon: Icon((playing.data ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: player.playOrPause,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SeekBar(player: player, color: Colors.white),
          ),
        ],
      ),
    ),
  );
}

class _Audio extends ConsumerWidget {
  const _Audio(this.attachment);
  final Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final deck = ref.watch(audioDeckProvider);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
                ),
                child: SizedBox.square(
                  dimension: 120,
                  child: Icon(kindIcon(attachment), size: 48, color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(height: 24),
              Text(attachment.name, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Transform.scale(scale: 1.4, child: AudioButton(attachment)),
              const SizedBox(height: 12),
              ValueListenableBuilder(
                valueListenable: deck.current,
                builder: (context, current, _) =>
                    current == attachment.id ? SeekBar(player: deck.player) : const SizedBox(height: 48),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Other extends StatelessWidget {
  const _Other(this.attachment, {required this.onSave});
  final Attachment attachment;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kindIcon(attachment), size: 64, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(attachment.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(formatSize(attachment.size), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          if (!attachment.pending)
            FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Save a copy'),
            ),
        ],
      ),
    );
  }
}
