/// Material's window size classes, and the room the detail pane takes.
/// One place for the breakpoints, so the board, the routes and the
/// dialogs never disagree about which kind of window they are in.
library;

import 'package:material_ui/material_ui.dart';

/// Compact windows (phones) are under 600dp wide; medium ones under 840;
/// expanded from there.
const compactBelow = 600.0;
const expandedFrom = 840.0;

bool isCompactWidth(double width) => width < compactBelow;
bool isExpandedWidth(double width) => width >= expandedFrom;

/// Under 600dp: navigation in chips and the account menu, full-screen
/// pages and sheets.
bool isCompact(BuildContext context) => isCompactWidth(MediaQuery.sizeOf(context).width);

/// From 840dp: the expanded rail, the detail pane, dialogs and menus.
bool isExpanded(BuildContext context) => isExpandedWidth(MediaQuery.sizeOf(context).width);

/// The detail pane's width for a window [width] wide: about a third of it,
/// never narrower than a phone nor wider than text reads well.
double detailPaneWidth(double width) => (width * 0.36).clamp(360.0, 520.0);

/// The space between the board and the detail pane, and around the pane.
const paneSpacer = 24.0;

/// How a compact window shows what an expanded one shows as a dialog.
enum CompactForm {
  /// A modal bottom sheet with a drag handle (pickers, short lists).
  sheet,

  /// A full-screen dialog (forms, settings: Material's pattern for a dialog
  /// with fields or a page of choices).
  fullscreen,
}

/// Shows [build]'s content Material's adaptive way: a basic dialog no
/// bigger than [maxWidth] by [maxHeight] on expanded windows, and on
/// compact and medium ones a bottom sheet or a full-screen dialog
/// ([compact]). [build] is told which it is in, for its own header and
/// actions. [dismissible] false keeps a tap outside (or a drag) from
/// closing it.
Future<T?> showAdaptive<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, bool inDialog) build,
  CompactForm compact = CompactForm.sheet,
  double maxWidth = 480,
  double maxHeight = 640,
  bool dismissible = true,
}) {
  if (isExpanded(context)) {
    return showDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: build(context, true),
        ),
      ),
    );
  }
  return switch (compact) {
    CompactForm.fullscreen => showDialog<T>(
      context: context,
      builder: (context) => Dialog.fullscreen(child: build(context, false)),
    ),
    CompactForm.sheet => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: dismissible,
      useSafeArea: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      builder: (context) => Padding(
        // the keyboard pushes a sheet with a field up, not over it
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: build(context, false),
        ),
      ),
    ),
  };
}
