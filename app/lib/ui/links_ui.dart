/// Links in notes, opened: the editor's list of them and the card's mark.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/links.dart';
import 'expressive.dart';
import 'feedback.dart';

/// Opens [uri] in the browser (or the app that handles it).
Future<void> openLink(Uri uri) async {
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // reported below
  }
  showMessage("Couldn't open ${linkLabel(uri)}");
}

/// The links in a note, under its text: a row each, opened with a tap, as
/// a segmented list.
class NoteLinks extends StatelessWidget {
  const NoteLinks({super.key, required this.links});
  final List<Uri> links;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SegmentedList(
        padding: EdgeInsets.zero,
        children: [
          for (final uri in links)
            ListTile(
              leading: Icon(Icons.link, color: scheme.onSurfaceVariant),
              title: Text(uri.host.replaceFirst(RegExp(r'^www\.'), ''), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(linkLabel(uri), maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.open_in_new, size: 20),
              onTap: () => unawaited(openLink(uri)),
            ),
        ],
      ),
    );
  }
}
