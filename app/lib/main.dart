import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'state/providers.dart';
import 'ui/app.dart';
import 'ui/feedback.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // libmpv on Linux, the platform players elsewhere: video and audio
  MediaKit.ensureInitialized();
  // files the server turned away, said once in a snackbar
  uploadFailures.stream.listen(showMessage);
  runApp(const ProviderScope(child: ChitApp()));
}
