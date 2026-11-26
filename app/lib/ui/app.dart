import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync.dart';
import '../state/providers.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'note_page.dart';
import 'theme.dart';

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
      GoRoute(path: '/note/new', builder: (_, state) => NotePage(list: state.uri.queryParameters['list'] == '1')),
      GoRoute(path: '/note/:id', builder: (_, state) => NotePage(noteId: state.pathParameters['id'])),
    ],
  );
});

class ChitApp extends ConsumerWidget {
  const ChitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The server turned the session away: back to sign-in.
    ref.listen(syncStatusProvider, (_, next) {
      if (next.value?.phase == SyncPhase.signedOut) ref.read(sessionProvider.notifier).signOut();
    });
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp.router(
        title: 'chit',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(light, Brightness.light),
        darkTheme: buildTheme(dark, Brightness.dark),
        routerConfig: ref.watch(_router),
      ),
    );
  }
}
