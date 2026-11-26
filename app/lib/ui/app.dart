import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync.dart';
import '../state/providers.dart';
import 'feedback.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'note_page.dart';
import 'theme.dart';
import 'theme_file.dart';
import 'theme_spec.dart';

/// The desktop theme file, live (null: none, or on the web and phones).
final themeSpecProvider = StreamProvider<ThemeSpec?>((ref) => watchThemeSpec());

final _router = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      if (session.isLoading) return null;
      final signedIn = session.value != null;
      final atLogin = state.matchedLocation == '/login';
      if (!signedIn) return atLogin ? null : '/login';
      return atLogin ? '/' : null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomePage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(
        path: '/note/new',
        pageBuilder: (context, state) => _notePage(
          context,
          state,
          (dialog) => NotePage(list: state.uri.queryParameters['list'] == '1', inDialog: dialog),
        ),
      ),
      GoRoute(
        path: '/note/:id',
        pageBuilder: (context, state) =>
            _notePage(context, state, (dialog) => NotePage(noteId: state.pathParameters['id'], inDialog: dialog)),
      ),
    ],
  );
});

/// A note opens full-screen on compact and medium windows, and as a dialog
/// over the board on expanded ones: Material's adaptive pattern for a detail
/// view, which keeps the notes in view behind it.
Page<void> _notePage(BuildContext context, GoRouterState state, Widget Function(bool dialog) page) =>
    isExpanded(context)
    ? _DialogPage(key: state.pageKey, child: page(true))
    : MaterialPage(key: state.pageKey, child: page(false));

class _DialogPage extends Page<void> {
  const _DialogPage({super.key, required this.child});
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => DialogRoute<void>(
    context: context,
    settings: this,
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      final theme = Theme.of(context);
      final radius = theme.dialogTheme.shape is RoundedRectangleBorder
          ? (theme.dialogTheme.shape! as RoundedRectangleBorder).borderRadius
          : const BorderRadius.all(Radius.circular(28));
      return Dialog(
        clipBehavior: Clip.antiAlias,
        // a hairline edge, so the dialog holds its shape on a black board
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        insetPadding: const EdgeInsets.all(32),
        child: SizedBox(width: 720, height: (size.height - 96).clamp(320, 820), child: child),
      );
    },
  );
}

class ChitApp extends ConsumerWidget {
  const ChitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The server turned the session away: back to sign-in.
    ref.listen(syncStatusProvider, (_, next) {
      if (next.value?.phase == SyncPhase.signedOut) ref.read(sessionProvider.notifier).signOut();
    });
    final spec = ref.watch(themeSpecProvider).value;
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp.router(
        title: 'chit',
        scaffoldMessengerKey: messengerKey,
        debugShowCheckedModeBanner: false,
        // a theme file decides light or dark itself
        theme: spec != null ? buildTheme(null, spec.brightness, spec) : buildTheme(light, Brightness.light),
        darkTheme: spec != null ? buildTheme(null, spec.brightness, spec) : buildTheme(dark, Brightness.dark),
        routerConfig: ref.watch(_router),
      ),
    );
  }
}
