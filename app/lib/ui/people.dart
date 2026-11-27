import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../state/providers.dart';

/// A person's name for [id] from the household list, or a placeholder.
String nameOf(List<Person> people, String id) {
  final p = people.where((p) => p.id == id).firstOrNull;
  return p == null ? 'Someone' : p.display;
}

/// A person's initial in a tonal circle. The container role is picked from
/// their id, so each person keeps the same color everywhere.
class PersonAvatar extends ConsumerWidget {
  const PersonAvatar({super.key, required this.id, this.radius = 16, this.ring});
  final String id;
  final double radius;

  /// An outline in this color (avatars overlapping on a card).
  final Color? ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final name = nameOf(people, id);
    final s = Theme.of(context).colorScheme;
    final tones = [
      (s.primaryContainer, s.onPrimaryContainer),
      (s.secondaryContainer, s.onSecondaryContainer),
      (s.tertiaryContainer, s.onTertiaryContainer),
    ];
    // FNV-1a over the id: neighbours in the alphabet still differ
    var h = 0x811c9dc5;
    for (final c in id.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    final (bg, fg) = tones[h % tones.length];
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundColor: fg,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(fontSize: radius * 0.9, fontWeight: FontWeight.w600),
      ),
    );
    return Semantics(
      label: name,
      excludeSemantics: true,
      child: ring == null
          ? avatar
          // around the face, not under it (a decoration's border is
          // painted beneath its child, which covered it)
          : Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
              child: avatar,
            ),
    );
  }
}
