import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../data/media.dart';
import '../data/sync.dart';
import '../state/providers.dart';
import 'audio_player.dart';
import 'feedback.dart';
import 'phone_notifications.dart';
import 'share_in.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'note_page.dart';
import 'note_routes.dart';
import 'theme.dart';
import 'theme_file.dart';
import 'system_colors.dart';
import 'theme_spec.dart';
import 'viewer.dart';

/// The desktop theme file, live (null: none, or on the web and phones).
final themeSpecProvider = StreamProvider<ThemeSpec?>((ref) => watchThemeSpec());

/// The app's navigator, for what lives above it (the mini player).
final _rootNavigator = GlobalKey<NavigatorState>(debugLabel: 'root');

final _router = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    navigatorKey: _rootNavigator,
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
          NoteOrigins.fresh,
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
        pageBuilder: (context, state) => _notePage(
          context,
          state,
          state.pathParameters['id']!,
          (dialog) => NotePage(noteId: state.pathParameters['id'], inDialog: dialog),
        ),
      ),
    ],
  );
});

/// A note opens as the whole window on compact and medium ones, grown out
/// of its card, and in the detail pane beside the board on expanded ones
/// (note_routes.dart).
Page<void> _notePage(BuildContext context, GoRouterState state, String origin, Widget Function(bool pane) page) =>
    isExpanded(context)
    ? NotePanePage(key: state.pageKey, child: page(true))
    : NoteOpenPage(key: state.pageKey, origin: origin, child: page(false));

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
  late final _inbox = ShareInbox(_received);
  late final _notifications = PhoneNotifications(ref, open: (note) => _open('/note/$note'));

  /// Shares that came in before there was anyone signed in to keep them.
  final _held = <Shared>[];

  /// Opens a note from outside the pages (a notification).
  void _open(String location) {
    final context = _rootNavigator.currentContext;
    if (context != null) unawaited(openNote(context, location));
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(systemSchemeProvider));
    _inbox.start();
    unawaited(_notifications.start());
  }

  @override
  void dispose() {
    _inbox.stop();
    _notifications.stop();
    _lifecycle.dispose();
    super.dispose();
  }

  void _received(Shared share) {
    _held.add(share);
    _deliver();
  }

  /// Each share becomes a new note (its text, its files), opened; held
  /// until someone is signed in.
  Future<void> _deliver() async {
    final engine = ref.read(engineProvider);
    if (engine == null) return;
    while (_held.isNotEmpty) {
      final s = _held.removeAt(0);
      if (s.tooBig.isNotEmpty) {
        showMessage(
          s.tooBig.length == 1
              ? '${s.tooBig.first} is over the ${maxAttachmentSize >> 20} MB limit'
              : '${s.tooBig.length} files are over the ${maxAttachmentSize >> 20} MB limit',
        );
      }
      final text = noteTextOf(s.text, s.subject);
      if (text.title.isEmpty && text.body.isEmpty && s.files.isEmpty) continue;
      final id = randomId();
      await engine.edit([
        engine.op(Collections.notes, id, 'kind', 'text'),
        if (text.title.isNotEmpty) engine.op(Collections.notes, id, 'title', text.title),
        if (text.body.isNotEmpty) engine.op(Collections.notes, id, 'body', text.body),
      ]);
      if (s.files.isNotEmpty) await attachFiles(ref.read(replicaProvider), engine, id, s.files);
      if (mounted) unawaited(ref.read(_router).push('/note/$id'));
    }
  }

  @override
  Widget build(BuildContext context) {
    // a share held for sign-in goes out once someone is
    ref.listen(engineProvider, (_, engine) {
      if (engine != null && _held.isNotEmpty) unawaited(_deliver());
    });
    // The server turned the session away: back to sign-in.
    ref.listen(syncStatusProvider, (_, next) {
      if (next.value?.phase == SyncPhase.signedOut) ref.read(sessionProvider.notifier).signOut();
    });
    final spec = ref.watch(themeSpecProvider).value;
    final system = ref.watch(systemSchemeProvider).value;
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp.router(
        title: 'chit',
        // the mini player docks below everything, snackbars included
        builder: (context, child) => AudioDock(
          navigatorKey: _rootNavigator,
          child: SnackbarHost(child: child ?? const SizedBox.shrink()),
        ),
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
