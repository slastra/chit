import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// Files here are real files.
const hasFiles = true;

/// A name safe as a path component.
String _safe(String name) {
  final s = name.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
  return s.isEmpty || s == '.' || s == '..' ? 'file' : s;
}

/// Keeps the app's own copy of a file being attached (the original may move
/// or vanish before the upload runs), from a path or from bytes. Returns the
/// copy's path.
Future<String> keepCopy(String id, String name, {String? from, Uint8List? bytes}) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/uploads/$id');
  await dir.create(recursive: true);
  final dest = File('${dir.path}/${_safe(name)}');
  if (from != null) {
    // a file another app shared is already our own copy in the cache:
    // move it rather than copy it again
    final cache = (await getApplicationCacheDirectory()).path;
    if (from.startsWith('$cache/share/')) {
      try {
        await File(from).rename(dest.path);
        return dest.path;
      } on FileSystemException {
        // another filesystem: copy below
      }
    }
    await File(from).copy(dest.path);
  } else {
    await dest.writeAsBytes(bytes ?? Uint8List(0), flush: true);
  }
  return dest.path;
}

/// The queued file's bytes, for the upload.
Future<({Stream<List<int>> stream, int length})> openUpload(Upload u) async {
  final f = File(u.path ?? '');
  return (stream: f.openRead(), length: await f.length());
}

/// Drops the copy once it has landed, or the upload was given up.
Future<void> removeCopy(Upload u) async {
  final p = u.path;
  if (p == null) return;
  try {
    await File(p).parent.delete(recursive: true);
  } on FileSystemException {
    // already gone
  }
}

/// Where a download is cached: one directory per variant (the original, or
/// a thumbnail size) and attachment, under the app's cache directory.
Future<String> cachePath(String variant, String id, String name) async =>
    '${(await getApplicationCacheDirectory()).path}/media/$variant/$id/${_safe(name)}';

/// The cached file if it is there.
Future<String?> cached(String path) async => await File(path).exists() ? path : null;

/// Streams [bytes] into [path] through a .part file, so a broken download
/// never looks complete.
Future<String> saveDownload(String path, Stream<List<int>> bytes) async {
  final part = File('$path.part');
  await part.parent.create(recursive: true);
  final sink = part.openWrite();
  try {
    await sink.addStream(bytes);
  } finally {
    await sink.close();
  }
  await part.rename(path);
  return path;
}

/// An image from a local path.
ImageProvider fileImage(String path) => FileImage(File(path));

/// Writes a copy of a file where the user chose to save it.
Future<void> copyTo(String from, String to) async => File(from).copy(to);

/// An image on the clipboard, for pasting into a note. Read with wl-paste
/// (the desk is Wayland; Flutter's own clipboard is text only). Null when
/// the clipboard offers plain text too: then the text paste wins.
Future<({String name, Uint8List bytes})?> clipboardImage() async {
  if (defaultTargetPlatform != TargetPlatform.linux || Platform.environment['WAYLAND_DISPLAY'] == null) return null;
  try {
    final types = await Process.run('wl-paste', ['--list-types']);
    if (types.exitCode != 0) return null;
    final offered = (types.stdout as String).split('\n').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    if (offered.any((t) => t == 'text/plain' || t.startsWith('text/plain;') || t == 'UTF8_STRING')) return null;
    final type = offered.firstWhere((t) => t.startsWith('image/'), orElse: () => '');
    if (type.isEmpty) return null;
    final r = await Process.run('wl-paste', ['--no-newline', '--type', type], stdoutEncoding: null);
    if (r.exitCode != 0) return null;
    final bytes = Uint8List.fromList(r.stdout as List<int>);
    final ext = switch (type) {
      'image/jpeg' => 'jpg',
      'image/svg+xml' => 'svg',
      _ => type.substring('image/'.length),
    };
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return (
      name:
          'Pasted image ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}.${two(now.second)}.$ext',
      bytes: bytes,
    );
  } on ProcessException {
    return null; // no wl-paste
  }
}

/// A scratch path for a recording.
Future<String> recordingPath(String ext) async =>
    '${(await getTemporaryDirectory()).path}/chit-memo-${DateTime.now().millisecondsSinceEpoch}.$ext';

/// A file's size on disk.
Future<int> sizeOf(String path) => File(path).length();

/// A whole file's bytes.
Future<Uint8List> readBytes(String path) => File(path).readAsBytes();
