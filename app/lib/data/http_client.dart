// The HTTP client for this platform. On the web the default client buffers
// a response whole, which would hold the change stream forever; the fetch
// client streams it. Everywhere else the dart:io client already streams.
export 'http_client_io.dart' if (dart.library.js_interop) 'http_client_web.dart';
