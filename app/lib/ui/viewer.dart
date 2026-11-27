import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../data/replica.dart';
import '../state/providers.dart';
import 'attachments.dart';
import 'audio_player.dart';
import 'expressive.dart';
import 'media_player.dart';
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
    removeAttachment(ref, a);
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
    final dark = themeFor(_darkScheme(Theme.of(context).colorScheme.primary), ref.watch(themeSpecProvider).value);
    final images = all.where((x) => x.isImage).toList();

    final Widget body = switch (a.kind) {
      MediaKind.image => _Images(
        images: images,
        controller: _pages ??= PageController(initialPage: images.indexOf(a).clamp(0, images.length)),
        onPage: (i) => setState(() => _current = images[i].id),
      ),
      MediaKind.pdf => _Pdf(a),
      MediaKind.video => VideoView(a),
      MediaKind.audio => AudioPlayerView(audio: a),
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
            appBar: _ViewerBar(
              attachment: a,
              onClose: () => context.pop(),
              onSave: a.pending ? null : () => _save(a),
              onRemove: () => _delete(a),
            ),
            body: SafeArea(top: false, child: body),
          ),
        ),
      ),
    );
  }
}

/// The viewer's top app bar: Material 3's small app bar with a subtitle
/// (m3.material.io app bars specs): 64dp on surface, 4dp from the edge to
/// the 48dp buttons and from the button to the headline, the headline in
/// title large on surface, the subtitle in label medium on surface variant.
class _ViewerBar extends StatelessWidget implements PreferredSizeWidget {
  const _ViewerBar({required this.attachment, required this.onClose, required this.onSave, required this.onRemove});
  final Attachment attachment;
  final VoidCallback onClose;
  final VoidCallback? onSave;
  final VoidCallback onRemove;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = attachment;
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: onClose),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onSurface),
                    ),
                    Text(
                      a.pending ? Attachment.uploadStatus(null) : '${formatSize(a.size)} · ${kindLabel(a)}',
                      maxLines: 1,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (onSave != null)
                IconButton(tooltip: 'Save a copy', icon: const Icon(Icons.download_outlined), onPressed: onSave),
              IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: onRemove),
              const SizedBox(width: 4),
            ],
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
          child: SizedBox(width: 200, child: WavyProgress(value: _progress == 0 ? null : _progress)),
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
        child: pictureHero(
          images[i],
          child: AttachmentImage(images[i], fit: BoxFit.contain, width: double.infinity, height: double.infinity),
        ),
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

/// The viewer's dark scheme from the app's primary, on black. Made once per
/// primary: a swipe between pictures rebuilds the page.
ColorScheme _darkScheme(Color primary) => _dark[primary] ??= ColorScheme.fromSeed(
  seedColor: primary,
  brightness: Brightness.dark,
  dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
).copyWith(surface: Colors.black, onSurface: Colors.white);
final _dark = <Color, ColorScheme>{};
