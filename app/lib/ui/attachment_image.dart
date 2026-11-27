/// Pictures in notes: an attachment drawn as an image (its upload mark on
/// it while it is on its way), its flight to the viewer, and a note's set of
/// them.
library;

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../state/providers.dart';
import 'file_row.dart';
import 'theme.dart';

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
        // decoded at about the size it is drawn, not the file's: a phone
        // photo is 12 megapixels, its card a few hundred pixels across.
        // Rounded up to a step, so a width easing on a resize is not a
        // decode a frame
        return LayoutBuilder(
          builder: (context, box) {
            // a crop to cover the box can need more than its width: a wide
            // picture in a tall tile is scaled by its height. The longer
            // side, with room, covers both
            final sides = [box.maxWidth, box.maxHeight, ?widget.height].where((d) => d.isFinite);
            final across = sides.isEmpty ? 0.0 : sides.reduce((a, b) => a > b ? a : b);
            final px = across * 1.5 * MediaQuery.devicePixelRatioOf(context);
            final step = (px / 256).ceil() * 256;
            return Image(
              image: step > 0 && widget.fit != BoxFit.contain
                  ? ResizeImage(image, width: step, policy: ResizeImagePolicy.fit)
                  : image,
              fit: widget.fit,
              width: widget.width,
              height: widget.height,
              gaplessPlayback: true,
              semanticLabel: a.name,
              errorBuilder: (_, _, _) => placeholder(broken: true),
            );
          },
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
    final progress = ref.watch(uploadProgressProvider.select((m) => m.value?[attachment.id]));
    final ink = onImage ? Colors.white : scheme.primary;
    final mark = progress == null
        ? Icon(Icons.cloud_upload_outlined, size: size, color: onImage ? Colors.white : scheme.onSurfaceVariant)
        : SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator(value: progress, strokeWidth: 2.5, color: ink),
          );
    final label = Attachment.uploadStatus(progress);
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
  const NoteImages({super.key, required this.images});
  final List<Attachment> images;

  /// One picture at most this tall; several in a carousel this tall, 4dp in
  /// from either side.
  static const maxHeight = 480.0;
  static const carouselHeight = 240.0;
  static const gap = 4.0;

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
      return ClipRRect(
        borderRadius: cardRadius(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: maxHeight),
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
          padding: const EdgeInsets.symmetric(horizontal: gap),
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
