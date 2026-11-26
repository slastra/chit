// Files on this device: the copy of an attached file kept until it uploads,
// and downloads cached for viewing. Native builds use the file system; the
// web build has none, so a queued file stays as bytes in the database and
// downloads are left to the browser's cache.
export 'local_files_io.dart' if (dart.library.js_interop) 'local_files_web.dart';
