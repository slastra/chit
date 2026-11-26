// drift's web worker: the database runs here, off the page's thread.
// Compiled to drift_worker.js by tool/web-assets.sh.
import 'package:drift/wasm.dart';

void main() => WasmDatabase.workerMainForOpen();
