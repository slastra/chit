import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/media.dart';

const _channel = MethodChannel('chit/share');

/// Something another app shared into chit (Android): its text and subject,
/// its files (copied into the cache), and the names of files over the
/// attachment limit, which were left out.
typedef Shared = ({String text, String subject, List<NewFile> files, List<String> tooBig});

/// A new note's title and text from a share: a link alone becomes a link
/// note titled by its site (or the share's subject), as Link does; other
/// text is the note's text, the subject its title.
({String title, String body}) noteTextOf(String text, String subject) {
  final t = text.trim();
  final s = subject.trim();
  if (RegExp(r'^https?://\S+$').hasMatch(t)) {
    final host = Uri.tryParse(t)?.host.replaceFirst(RegExp(r'^www\.'), '') ?? '';
    return (title: s.isNotEmpty ? s : host, body: t);
  }
  return (title: s, body: t);
}

Shared _parse(Map<Object?, Object?> m) => (
  text: m['text'] as String? ?? '',
  subject: m['subject'] as String? ?? '',
  files: [
    for (final f in (m['files'] as List? ?? const []).cast<Map<Object?, Object?>>())
      (name: f['name']! as String, size: (f['size']! as num).toInt(), path: f['path'] as String?, bytes: null),
  ],
  tooBig: [...(m['tooBig'] as List? ?? const []).cast<String>()],
);

/// Shares arriving from other apps, handed to [onShare] as they come
/// (Android only; elsewhere it does nothing).
final class ShareInbox {
  ShareInbox(this.onShare);
  final void Function(Shared share) onShare;

  void start() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await _take();
    });
    unawaited(_take());
  }

  Future<void> _take() async {
    try {
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>('take') ?? const [];
      for (final m in list) {
        onShare(_parse(m));
      }
    } on MissingPluginException {
      // not the Android app
    }
  }

  void stop() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler(null);
  }
}
