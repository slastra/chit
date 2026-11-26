import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'database.dart';

/// No file system on the web: queued files are bytes, downloads are URLs.
const hasFiles = false;

Future<String> keepCopy(String id, String name, {String? from, Uint8List? bytes}) =>
    throw UnsupportedError('no files on the web');

Future<({Stream<List<int>> stream, int length})> openUpload(Upload u) async {
  final b = u.bytes ?? Uint8List(0);
  return (stream: Stream<List<int>>.value(b), length: b.length);
}

Future<void> removeCopy(Upload u) async {}

Future<String> cachePath(String variant, String id, String name) => throw UnsupportedError('no files on the web');

Future<String?> cached(String path) async => null;

Future<String> saveDownload(String path, Stream<List<int>> bytes) => throw UnsupportedError('no files on the web');

ImageProvider fileImage(String path) => throw UnsupportedError('no files on the web');

Future<void> copyTo(String from, String to) => throw UnsupportedError('no files on the web');

Future<({String name, Uint8List bytes})?> clipboardImage() async => null;

Future<String> recordingPath(String ext) async => '';

Future<int> sizeOf(String path) async => 0;

Future<Uint8List> readBytes(String path) => throw UnsupportedError('no files on the web');
