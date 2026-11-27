/// Files in notes that are not pictures: what kind each is, opening one,
/// and its row in the editor (a PDF's first page, audio playing in place).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../state/providers.dart';
import 'audio_player.dart';
import 'expressive.dart';
import 'media_deck.dart';
import 'attachment_image.dart';
import 'feedback.dart';

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
  MediaKind.audio => a.name.startsWith(voiceMemoName) ? Icons.mic_none : Icons.music_note_outlined,
  MediaKind.pdf => Icons.picture_as_pdf_outlined,
  MediaKind.other => Icons.insert_drive_file_outlined,
};

/// Takes [a] off its note: a file still waiting to upload just leaves the
/// queue; one already sent is marked deleted, with Undo.
void removeAttachment(WidgetRef ref, Attachment a) {
  if (a.pending) {
    unawaited(ref.read(replicaProvider).dropUpload(a.id));
    return;
  }
  final engine = ref.read(engineProvider);
  if (engine == null) return;
  unawaited(engine.edit([engine.op(Collections.attachments, a.id, 'deleted', true)]));
  showUndo('File removed', () => engine.edit([engine.op(Collections.attachments, a.id, 'deleted', false)]));
}

void openAttachment(BuildContext context, Attachment a) => a.kind == MediaKind.audio
    ? unawaited(showAudioPlayer(context, a))
    : unawaited(context.push('/note/${a.note}/file/${a.id}'));

/// A PDF's first page, small, for its row.
class _PdfFirstPage extends ConsumerStatefulWidget {
  const _PdfFirstPage(this.attachment);
  final Attachment attachment;

  @override
  ConsumerState<_PdfFirstPage> createState() => _PdfFirstPageState();
}

class _PdfFirstPageState extends ConsumerState<_PdfFirstPage> {
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
    final progress = ref.watch(uploadProgressProvider.select((m) => m.value?[a.id]));
    final detail = a.pending ? Attachment.uploadStatus(progress) : '${formatSize(a.size)} · ${kindLabel(a)}';
    final Widget leading = switch (a.kind) {
      MediaKind.pdf => _PdfFirstPage(a),
      MediaKind.audio => _AudioButton(a),
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
        if (a.kind == MediaKind.audio) _AudioProgress(a),
      ],
    );
  }
}

/// Play and pause, in a row's leading slot.
class _AudioButton extends ConsumerWidget {
  const _AudioButton(this.attachment);
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

/// The playing row's seek bar and times; nothing for the rows not playing.
class _AudioProgress extends ConsumerWidget {
  const _AudioProgress(this.attachment);
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
