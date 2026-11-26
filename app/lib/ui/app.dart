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
import 'system_colors.dart';
import 'theme_spec.dart';
import 'viewer.dart';

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
      // an attachment, full screen above everything, the note's dialog too
      GoRoute(
        path: '/note/:id/file/:att',
        pageBuilder: (context, state) => MaterialPage(
          key: state.pageKey,
          fullscreenDialog: true,
          child: ViewerPage(noteId: state.pathParameters['id']!, attachmentId: state.pathParameters['att']!),
        ),
      ),
      GoRoute(
        path: '/note/new',
        pageBuilder: (context, state) => _notePage(
          context,
          state,
          (dialog) => NotePage(
            list: state.uri.queryParameters['list'] == '1',
            initialTitle: state.uri.queryParameters['title'] ?? '',
            initialBody: state.uri.queryParameters['text'] ?? '',
            inDialog: dialog,
          ),
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
      // the editor as a basic dialog: Material's large-screen form of a
      // full-screen dialog, at most 560dp wide, in its theme shape and color
      return Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(32),
        child: SizedBox(width: 560, height: (size.height - 96).clamp(320, 820), child: child),
      );
    },
  );
}

/// Android's own color scheme, read again whenever the app comes back to
/// the foreground (the wallpaper, and so the scheme, may have changed).
final systemSchemeProvider = FutureProvider<({ColorScheme light, ColorScheme dark})?>((ref) => systemSchemes());

class ChitApp extends ConsumerStatefulWidget {
  const ChitApp({super.key});

  @override
  ConsumerState<ChitApp> createState() => _ChitAppState();
}

class _ChitAppState extends ConsumerState<ChitApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(systemSchemeProvider));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The server turned the session away: back to sign-in.
    ref.listen(syncStatusProvider, (_, next) {
      if (next.value?.phase == SyncPhase.signedOut) ref.read(sessionProvider.notifier).signOut();
    });
    final spec = ref.watch(themeSpecProvider).value;
    final system = ref.watch(systemSchemeProvider).value;
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp.router(
        title: 'chit',
        builder: (context, child) => SnackbarHost(child: child ?? const SizedBox.shrink()),
        debugShowCheckedModeBanner: false,
        // Where the colors come from, first match wins: the desktop's theme
        // file (it decides light or dark itself); Android's own scheme, as
        // is; the wallpaper palette (older Android); chit's seed.
        theme: spec != null
            ? buildTheme(null, spec.brightness, spec)
            : system != null
            ? themeFor(system.light)
            : buildTheme(light, Brightness.light),
        darkTheme: spec != null
            ? buildTheme(null, spec.brightness, spec)
            : system != null
            ? themeFor(system.dark)
            : buildTheme(dark, Brightness.dark),
        routerConfig: ref.watch(_router),
      ),
    );
  }
}
