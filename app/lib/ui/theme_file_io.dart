import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'theme_spec.dart';

File _file() {
  final home = Platform.environment['HOME'] ?? '';
  final config = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  return File('$config/chit/theme.json');
}

Future<ThemeSpec?> _read(File f) async {
  try {
    return ThemeSpec.fromJson(jsonDecode(await f.readAsString()));
  } on Object {
    return null; // missing, or caught mid-write: the next event reads it whole
  }
}

/// The theme now, then again after every change. Watches the directory, not
/// the file: tint replaces the file whole, which a file watch would lose.
Stream<ThemeSpec?> watchThemeSpec() async* {
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
    yield null;
    return;
  }
  final f = _file();
  yield await _read(f);
  final dir = f.parent;
  if (!dir.existsSync()) return;
  await for (final e in dir.watch()) {
    if (e.path.endsWith('theme.json')) yield await _read(f);
  }
}
