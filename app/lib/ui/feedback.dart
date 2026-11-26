import 'package:material_ui/material_ui.dart';

/// The app's one messenger, so a snackbar outlives the page that raised it
/// (archive a note, the editor closes, the Undo stays on the home screen).
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// A floating snackbar with Undo: Material's answer to a reversible action,
/// instead of asking first.
void showUndo(String message, VoidCallback undo) {
  final context = messengerKey.currentContext;
  // Material's snackbar is at most 600dp wide
  final wide = context != null && MediaQuery.sizeOf(context).width >= 600 + 2 * 12;
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        width: wide ? 600 : null,
        action: SnackBarAction(label: 'Undo', onPressed: undo),
      ),
    );
}
