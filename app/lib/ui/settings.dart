import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../notifications.dart';
import '../state/providers.dart';
import 'expressive.dart';
import 'haptics.dart';
import 'home_page.dart' show isExpanded;
import 'labels_ui.dart';

/// Whether this phone tells of other people's edits to shared notes.
final _notifyActivityProvider = FutureProvider<bool>((ref) => activityEnabled(ref.watch(replicaProvider)));

const _power = MethodChannel('chit/power');

/// Whether Android leaves the background catch-up alone (no battery
/// optimization); null where it doesn't apply.
final _exemptProvider = FutureProvider<bool?>((ref) async {
  try {
    return await _power.invokeMethod<bool>('exempt');
  } on MissingPluginException {
    return null;
  }
});

/// Settings: the account, labels, and on a phone its notifications. A
/// dialog on expanded windows, a full-screen one on compact ones.
Future<void> showSettings(BuildContext context) {
  if (isExpanded(context)) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: const _Settings(fullscreen: false),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => const Dialog.fullscreen(child: _Settings(fullscreen: true)),
  );
}

class _Settings extends ConsumerWidget {
  const _Settings({required this.fullscreen});
  final bool fullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = ref.watch(sessionProvider).value;
    final name = session?.user.display ?? '';

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 8),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
    );

    final list = ListView(
      shrinkWrap: !fullscreen,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        heading('Account'),
        SegmentedList(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()),
              ),
              title: Text(name),
              subtitle: session == null ? null : Text(Uri.parse(session.server).host),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () {
                Navigator.pop(context);
                unawaited(ref.read(sessionProvider.notifier).signOut());
              },
            ),
          ],
        ),
        heading('Notes'),
        SegmentedList(
          children: [
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Labels'),
              subtitle: const Text('Create, rename and delete'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showEditLabels(context),
            ),
          ],
        ),
        if (notificationsSupported) ...[
          heading('Notifications'),
          SegmentedList(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.group_outlined),
                title: const Text('Shared edits'),
                subtitle: const Text('When someone changes a note shared with you'),
                value: ref.watch(_notifyActivityProvider).value ?? true,
                onChanged: (v) async {
                  tick();
                  await setActivityEnabled(ref.read(replicaProvider), v);
                  if (v) await askNotificationPermission();
                  ref.invalidate(_notifyActivityProvider);
                },
              ),
              // battery optimization otherwise stretches the 15-minute
              // catch-up to hours
              if (ref.watch(_exemptProvider).value case final exempt?)
                ListTile(
                  leading: const Icon(Icons.sync_outlined),
                  title: const Text('Background sync'),
                  subtitle: Text(
                    exempt
                        ? 'chit checks for changes while it is closed'
                        : 'Let chit check for changes while it is closed',
                  ),
                  trailing: exempt
                      ? Icon(Icons.check_circle, color: scheme.primary)
                      : FilledButton.tonal(
                          onPressed: () async {
                            await _power.invokeMethod<void>('ask');
                            ref.invalidate(_exemptProvider);
                          },
                          child: const Text('Allow'),
                        ),
                ),
            ],
          ),
        ],
      ],
    );

    if (fullscreen) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          title: const Text('Settings'),
        ),
        body: list,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Text('Settings', style: theme.textTheme.headlineSmall),
        ),
        Flexible(child: list),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ),
        ),
      ],
    );
  }
}
