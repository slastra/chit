import 'dart:async';
import 'dart:typed_data';

import '../core/protocol.dart';
import 'api.dart';
import 'local_files.dart';
import 'replica.dart';

/// The largest file an attachment may hold (the server's
/// protocol.MaxAttachmentSize): 250 MB.
const maxAttachmentSize = 250 << 20;

/// A file picked, pasted, dropped or recorded, on its way to a note.
typedef NewFile = ({String name, int size, String? path, Uint8List? bytes});

/// A MIME type from a file name, for showing a file before the server has
/// sniffed it.
String guessType(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'avif' => 'image/avif',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mkv' => 'video/x-matroska',
    '3gp' => 'video/3gpp',
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };
}

/// Sizes the way people read them.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

/// Attachments for viewing: tokenized URLs, and on native platforms cached
/// downloads. A file still waiting to upload is read from its local copy.
final class Media {
  Media(this.api, this.replica);

  final ChitApi api;
  final Replica replica;

  // PocketBase's file tokens are short-lived; one serves many requests.
  String? _token;
  DateTime _tokenAt = DateTime(0);
  Future<String>? _tokenFetch;
  final _downloads = <String, Future<String>>{};

  Future<String> _fileToken() async {
    if (_token != null && DateTime.now().difference(_tokenAt) < const Duration(seconds: 90)) return _token!;
    return _tokenFetch ??= api
        .fileToken()
        .then((t) {
          _token = t;
          _tokenAt = DateTime.now();
          return t;
        })
        .whenComplete(() => _tokenFetch = null);
  }

  /// A URL for [a] (or an image thumbnail: "320x320", "1080x0").
  Future<Uri> url(Attachment a, {String? thumb}) async =>
      api.fileUrl(a, await _fileToken(), thumb: a.isImage ? thumb : null);

  /// A local file for [a]: its own copy while it waits to upload, else a
  /// cached download. Null on the web, which has no files (use [url], or
  /// [pendingBytes] for a file not uploaded yet).
  Future<String?> file(Attachment a, {String? thumb, void Function(double fraction)? onProgress}) async {
    if (!hasFiles) return null;
    if (a.pending) return a.local.isEmpty ? null : a.local;
    final variant = a.isImage && thumb != null ? thumb : 'file';
    final path = await cachePath(variant, a.id, a.name);
    if (await cached(path) case final hit?) return hit;
    try {
      return await (_downloads[path] ??= _download(a, thumb, variant, path, onProgress).whenComplete(() {
        // a block, not `=> _downloads.remove(path)`: that returns this very
        // future, and whenComplete would wait on it, forever
        _downloads.remove(path);
      }));
    } catch (_) {
      // offline, say: any copy of an image already here beats none
      if (a.isImage) {
        for (final other in const ['1080x0', 'file', '320x320']) {
          if (other == variant) continue;
          if (await cached(await cachePath(other, a.id, a.name)) case final hit?) return hit;
        }
      }
      rethrow;
    }
  }

  Future<String> _download(
    Attachment a,
    String? thumb,
    String variant,
    String path,
    void Function(double fraction)? onProgress,
  ) async {
    final body = await api.download(await url(a, thumb: thumb));
    var got = 0;
    final total = variant == 'file' ? a.size : 0;
    return saveDownload(
      path,
      body.map((chunk) {
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
        return chunk;
      }),
    );
  }

  /// The bytes of a file still waiting to upload, on the web.
  Future<Uint8List?> pendingBytes(Attachment a) async => (await replica.upload(a.id))?.bytes;
}
