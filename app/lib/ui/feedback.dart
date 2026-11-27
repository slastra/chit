import 'package:material_ui/material_ui.dart';

/// The window's snackbar host. [SnackbarHost] puts it above every route,
/// dialogs included, so a message shows exactly once, at the foot of the
/// window, and outlives the page that raised it (archive a note: the editor
/// closes, the Undo stays).
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Room to keep clear above the bottom edge, for a FAB the snackbar must not
/// cover (Material sets snackbars above FABs). The page that shows the FAB
/// sets it; the host's own scaffold has none to measure.
double snackbarClearance = 0;

/// Wraps the app's navigator (MaterialApp.builder) in one ScaffoldMessenger
/// and a transparent Scaffold. Every page's Scaffold then sits inside that
/// one, so the messenger presents on it alone: a ScaffoldMessenger shows a
/// snackbar on every root Scaffold it knows, and a dialog's page is a root of
/// its own, which is how the editor and the board each got a copy.
class SnackbarHost extends StatelessWidget {
  const SnackbarHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ScaffoldMessenger(
    key: messengerKey,
    child: Scaffold(backgroundColor: Colors.transparent, resizeToAvoidBottomInset: false, body: child),
  );
}

/// A plain message, timed like the rest.
void showMessage(String message) => _show(message);

/// A snackbar with Undo: Material's answer to a reversible action, instead
/// of asking first. Timed: with an action a snackbar would otherwise stay
/// until dismissed (screen readers keep it regardless, as they should).
void showUndo(String message, VoidCallback undo) => _show(message, undo: undo);

/// A floating snackbar, at most 600dp wide, clear of the FAB, for six
/// seconds; one with Undo takes the place of any showing.
void _show(String message, {VoidCallback? undo}) {
  final context = messengerKey.currentContext;
  final messenger = messengerKey.currentState;
  if (context == null || messenger == null) return;
  final wide = MediaQuery.sizeOf(context).width >= 600 + 2 * 12;
  if (undo != null) messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      width: wide ? 600 : null,
      margin: wide ? null : EdgeInsets.fromLTRB(12, 0, 12, 12 + snackbarClearance),
      duration: const Duration(seconds: 6),
      persist: undo == null ? null : false,
      action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: undo),
    ),
  );
}
