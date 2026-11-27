import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// How a note opens, by window size (Material's list-detail layout):
///
/// - compact and medium windows: the whole window, grown out of the note's
///   card (or the new-note button) by a container transform, and shrunk
///   back into it on the way out; on Android the Back gesture drags it
/// - expanded windows: a detail pane beside the board, which stays in use
bool isExpandedWidth(double width) => width >= 840;

/// The detail pane's width for a window [width] wide: about a third of it,
/// never narrower than a phone nor wider than text reads well.
double detailPaneWidth(double width) => (width * 0.36).clamp(360.0, 520.0);

/// The space between the board and the detail pane, and around the pane.
const paneSpacer = 24.0;

/// Whether a note is open on [router]'s stack (under a viewer, too).
bool noteRouteOpen(GoRouter router) => openNoteId(router) != null;

/// The note open on [router]'s stack: its id, 'new' for one not kept yet,
/// null for none.
String? openNoteId(GoRouter router) {
  for (final m in router.routerDelegate.currentConfiguration.matches.reversed) {
    final parts = Uri.parse(m.matchedLocation).pathSegments;
    if (parts.length >= 2 && parts.first == 'note') return parts[1];
  }
  return null;
}

/// Opens the note at [location] (`/note/<id>`, `/note/new?...`). Beside the
/// board there is one detail pane: a note opened while another is open
/// takes its place.
Future<void> openNote(BuildContext context, String location) async {
  final router = GoRouter.of(context);
  if (isExpandedWidth(MediaQuery.sizeOf(context).width) && noteRouteOpen(router)) {
    router.pushReplacement(location);
    return;
  }
  await router.push(location);
}

// ---- where notes open from -------------------------------------------------------

/// Where on screen each note's card is (and the new-note button, as
/// [NoteOrigins.fresh]), for the container transform to grow from and
/// shrink back to. Looked up as the transition runs, so a card that moved
/// meanwhile is still found.
abstract final class NoteOrigins {
  static const fresh = 'new';
  static final _origins = <String, List<_Origin>>{};

  /// The global rect of [id]'s origin and its corner radius, if on screen.
  static ({Rect rect, double radius})? of(String id) {
    for (final o in (_origins[id] ?? const <_Origin>[]).reversed) {
      final box = o.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final inset = o.inset;
      final rect =
          box.localToGlobal(Offset(inset.left, inset.top)) &
          Size(box.size.width - inset.horizontal, box.size.height - inset.vertical);
      if (rect.isEmpty) continue;
      return (rect: rect, radius: o.radius);
    }
    return null;
  }
}

class _Origin {
  _Origin(this.context, this.inset, this.radius);
  final BuildContext context;
  EdgeInsets inset;
  double radius;
}

/// Marks its child as where note [id] opens from. [inset] is any part of
/// the child's box that is not the thing itself (a card's overhang).
class NoteOrigin extends StatefulWidget {
  const NoteOrigin({super.key, required this.id, this.inset = EdgeInsets.zero, this.radius = 12, required this.child});
  final String id;
  final EdgeInsets inset;
  final double radius;
  final Widget child;

  @override
  State<NoteOrigin> createState() => _NoteOriginState();
}

class _NoteOriginState extends State<NoteOrigin> {
  late final _origin = _Origin(context, widget.inset, widget.radius);
  late String _id = widget.id;

  @override
  void initState() {
    super.initState();
    (NoteOrigins._origins[_id] ??= []).add(_origin);
  }

  @override
  void didUpdateWidget(NoteOrigin old) {
    super.didUpdateWidget(old);
    _origin
      ..inset = widget.inset
      ..radius = widget.radius;
    if (widget.id != _id) {
      NoteOrigins._origins[_id]?.remove(_origin);
      _id = widget.id;
      (NoteOrigins._origins[_id] ??= []).add(_origin);
    }
  }

  @override
  void dispose() {
    NoteOrigins._origins[_id]?.remove(_origin);
    if (NoteOrigins._origins[_id]?.isEmpty ?? false) NoteOrigins._origins.remove(_id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---- the whole window: a container transform ---------------------------------

/// A note as the whole window, grown out of [origin]'s place on screen.
class NoteOpenPage extends Page<void> {
  const NoteOpenPage({super.key, required this.origin, required this.child});

  /// A [NoteOrigins] id: the note's, or [NoteOrigins.fresh].
  final String origin;
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _NoteOpenRoute(this);
}

class _NoteOpenRoute extends PageRoute<void> {
  _NoteOpenRoute(NoteOpenPage page) : super(settings: page);

  NoteOpenPage get _page => settings as NoteOpenPage;

  @override
  bool get opaque => true;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;

  // Material's container transform: 500ms in on the emphasized curve, a
  // little quicker out
  @override
  Duration get transitionDuration => Durations.long2;
  @override
  Duration get reverseTransitionDuration => Durations.medium4;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      Semantics(scopesRoute: true, explicitChildNodes: true, child: _page.child);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _BackGesture(
    route: this,
    child: _ContainerTransform(animation: animation, origin: _page.origin, child: child),
  );
}

/// Grows [child] out of its origin's rect to the whole window: the
/// container's bounds and corners ease across, the page inside scaled to
/// the container's width from its top, fading in once it has some size; a
/// scrim dims what is left behind. Without an origin on screen (a link, a
/// notification), the page fades in and rises a little instead.
class _ContainerTransform extends StatelessWidget {
  const _ContainerTransform({required this.animation, required this.origin, required this.child});
  final Animation<double> animation;
  final String origin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final scrim = Theme.of(context).colorScheme.scrim;
    final outline = Theme.of(context).colorScheme.outlineVariant;
    return LayoutBuilder(
      builder: (context, box) {
        final full = Offset.zero & box.biggest;
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final v = animation.value;
            if (v >= 1) return child!;
            // forward and back along the same path, as a drag needs
            final t = Curves.easeInOutCubicEmphasized.transform(v);
            final from = NoteOrigins.of(origin);
            if (from == null) {
              return Opacity(
                opacity: Curves.easeOut.transform(v),
                child: Transform.translate(offset: Offset(0, 24 * (1 - t)), child: child),
              );
            }
            // the origin, in this route's own space
            final here = context.findRenderObject();
            final shift = here is RenderBox && here.attached ? here.localToGlobal(Offset.zero) : Offset.zero;
            final rect = Rect.lerp(from.rect.shift(-shift), full, t)!;
            final scale = rect.width / full.width;
            return Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(color: scrim.withValues(alpha: 0.32 * t)),
                  ),
                ),
                Positioned.fromRect(
                  rect: rect,
                  // the container fades in at once, hiding the card it grows from
                  child: Opacity(
                    opacity: const Interval(0, 0.1).transform(v),
                    child: Material(
                      color: surface,
                      elevation: 6 * math.sin(math.pi * t),
                      // the card's hairline, let go of as it becomes the page
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(lerpDouble(from.radius, 0, t)!),
                        side: BorderSide(color: outline.withValues(alpha: 1 - t)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minWidth: full.width,
                        maxWidth: full.width,
                        minHeight: full.height,
                        maxHeight: full.height,
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.topCenter,
                          // the page itself comes in once the container has grown some
                          child: Opacity(opacity: const Interval(0.15, 0.5).transform(v), child: child),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Android's predictive Back, driving [route]'s own transition: the note
/// shrinks toward its card under the finger, and goes there (or comes
/// back) when the finger lifts.
class _BackGesture extends StatefulWidget {
  const _BackGesture({required this.route, required this.child});
  final PageRoute<void> route;
  final Widget child;

  @override
  State<_BackGesture> createState() => _BackGestureState();
}

class _BackGestureState extends State<_BackGesture> with WidgetsBindingObserver {
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    // only a swipe, on the page in front, with nothing of its own to say
    // about Back (unsaved state, an open menu)
    if (backEvent.isButtonEvent || !route.isCurrent || !route.popGestureEnabled) return false;
    _dragging = true;
    route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_dragging) widget.route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (!_dragging) return;
    _dragging = false;
    widget.route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (!_dragging) return;
    _dragging = false;
    widget.route.handleCommitBackGesture();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---- beside the board: the detail pane -----------------------------------------

/// A note in the detail pane: at the window's end, beside the board. The
/// route has no barrier and takes no pointer outside the pane, so the board
/// beside it stays in use (the home page leaves the pane its room).
class NotePanePage extends Page<void> {
  const NotePanePage({super.key, required this.child});
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _NotePaneRoute(this);
}

class _NotePaneRoute extends PageRoute<void> {
  _NotePaneRoute(NotePanePage page) : super(settings: page);

  @override
  bool get opaque => false;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get barrierDismissible => false;

  @override
  Duration get transitionDuration => Durations.medium4;
  @override
  Duration get reverseTransitionDuration => Durations.short4;

  // no barrier: what is beside the pane is not behind a modal
  @override
  Widget buildModalBarrier() => const SizedBox.shrink();

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final width = MediaQuery.sizeOf(context).width;
    final theme = Theme.of(context);
    return SafeArea(
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          // level with the search bar's top, the window's margin at its end
          padding: const EdgeInsetsDirectional.fromSTEB(0, 8, paneSpacer, paneSpacer),
          child: SizedBox(
            width: detailPaneWidth(width),
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              child: Material(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: theme.dialogTheme.shape ?? RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                clipBehavior: Clip.antiAlias,
                child: (settings as NotePanePage).child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // a pane arrives from the window's end, as a side sheet does
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final slide = Tween(begin: Offset(rtl ? -0.12 : 0.12, 0), end: Offset.zero).animate(
      CurvedAnimation(parent: animation, curve: Easing.emphasizedDecelerate, reverseCurve: Easing.emphasizedAccelerate),
    );
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.6)),
      child: SlideTransition(position: slide, child: child),
    );
  }
}
