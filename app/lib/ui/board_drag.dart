import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'masonry.dart';

/// Where a dragged note would land: its section, and the note it goes in
/// front of (null: the section's end).
typedef Anchor = ({bool pinned, String? before});

/// Tags for the board's headers, so the drag can tell them from notes.
const pinnedHeader = '#pinned';
const othersHeader = '#others';
const pinZone = '#pinzone';

enum DragPhase { idle, lifted, dropping }

/// A note being dragged around the board: which one, where the pointer is,
/// and where it would land. The board reads [anchor] to show the note's
/// slot there (every other card glides aside, see masonry.dart); the
/// overlay draws the lifted card.
///
/// Lifting: a mouse press that travels 6px (a click still opens the note;
/// Flutter's tap gives up after a pixel of travel anyway), or a long press
/// on touch (moving first scrolls, as always).
class BoardDrag extends ChangeNotifier {
  BoardDrag({required this.gridKey, required this.cardFor, required this.onDrop});

  /// The board's Masonry.
  final GlobalKey gridKey;

  /// The lifted card's look (the note's card, drawn again).
  final Widget Function(String id) cardFor;

  /// Called when a drag ends somewhere new: the note, where it lands.
  final void Function(String id, Anchor anchor) onDrop;

  String? id;
  DragPhase phase = DragPhase.idle;
  Anchor? anchor;
  Anchor? _origin;

  /// The board's sections as the board shows them now (the board sets
  /// this every build): pinned ids, then the others.
  ({List<String> pinned, List<String> others}) sections = (pinned: const [], others: const []);

  Offset _pointer = Offset.zero;
  Offset _grab = Offset.zero; // where the card was held, from its corner
  Size _size = Size.zero;
  Offset _lastChange = Offset.zero;
  OverlayEntry? _overlay;
  EdgeDraggingAutoScroller? _scroller;
  _Lift? _lift;

  bool get active => id != null;

  RenderMasonry? get _grid => gridKey.currentContext?.findRenderObject() as RenderMasonry?;

  /// The note at [global], if a card is there (at rest).
  ({String id, Rect rect})? noteAt(Offset global) {
    final grid = _grid;
    if (grid == null || !grid.attached) return null;
    final local = grid.globalToLocal(global);
    for (final t in grid.targets) {
      final tag = t.data.tag;
      if (tag == null || tag.startsWith('#') || t.data.span) continue;
      if (t.target.contains(local)) return (id: tag, rect: t.target);
    }
    return null;
  }

  /// Picks the note at [global] up.
  bool lift(Offset global, BuildContext context) {
    final grid = _grid;
    final hit = noteAt(global);
    if (grid == null || hit == null) return false;
    id = hit.id;
    _origin = anchor = _anchorOf(hit.id);
    _size = hit.rect.size;
    _grab = grid.globalToLocal(global) - hit.rect.topLeft;
    _pointer = _lastChange = global;
    phase = DragPhase.lifted;
    unawaited(HapticFeedback.mediumImpact());
    final scrollable = Scrollable.maybeOf(gridKey.currentContext!);
    _scroller = scrollable == null
        ? null
        : EdgeDraggingAutoScroller(scrollable, onScrollViewScrolled: _reevaluate, velocityScalar: 30);
    HardwareKeyboard.instance.addHandler(_onKey);
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
    notifyListeners();
    return true;
  }

  /// The pointer moved to [global].
  void move(Offset global) {
    if (phase != DragPhase.lifted) return;
    _pointer = global;
    _overlay?.markNeedsBuild();
    _scroller?.startAutoScrollIfNecessary((global - _grab) & _size);
    _reevaluate();
  }

  /// The pointer let go: the card flies into its slot, and the move is
  /// sent if it landed somewhere new.
  void drop() {
    if (phase != DragPhase.lifted) return;
    _scroller?.stopAutoScroll();
    final moved = id!, landed = anchor!, from = _origin!;
    _settle(() {
      if (landed != from) onDrop(moved, landed);
    });
  }

  /// Puts the note back where it was.
  void cancel() {
    if (phase != DragPhase.lifted) return;
    _scroller?.stopAutoScroll();
    anchor = _origin;
    notifyListeners();
    _settle(null);
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && phase == DragPhase.lifted) {
      cancel();
      return true;
    }
    return false;
  }

  Anchor _anchorOf(String note) {
    final pinned = sections.pinned.contains(note);
    final list = pinned ? sections.pinned : sections.others;
    final i = list.indexOf(note);
    return (pinned: pinned, before: i + 1 < list.length ? list[i + 1] : null);
  }

  /// Finds where the pointer would put the note. Measured against cards'
  /// resting places (never where they are drawn mid-glide, which would chase
  /// itself), and steady: a new spot only counts if the note's slot, there,
  /// would sit under the pointer, or once the pointer has gone a third of a
  /// card on since the last change.
  void _reevaluate() {
    final grid = _grid;
    final me = id;
    if (grid == null || me == null || phase != DragPhase.lifted) return;
    final local = grid.globalToLocal(_pointer);
    final ts = grid.targets;
    final mine = ts.where((t) => t.data.tag == me).firstOrNull;
    if (mine == null || mine.target.contains(local)) return;

    Anchor? candidate;
    for (final t in ts) {
      if (t.data.tag == null || t.data.tag == me || !t.target.contains(local)) continue;
      final tag = t.data.tag!;
      if (tag == pinnedHeader || tag == pinZone) {
        candidate = (pinned: true, before: null);
      } else if (tag == othersHeader) {
        final first = sections.others.where((x) => x != me).firstOrNull;
        candidate = (pinned: false, before: first);
      } else {
        final pinned = sections.pinned.contains(tag);
        final list = [...(pinned ? sections.pinned : sections.others)]..remove(me);
        final upper = local.dy < t.target.center.dy;
        final i = list.indexOf(tag);
        candidate = (pinned: pinned, before: upper ? tag : (i + 1 < list.length ? list[i + 1] : null));
      }
      break;
    }
    if (candidate == null || candidate == anchor) return;

    final steady = _slotUnderPointer(grid, candidate, local) || (_pointer - _lastChange).distance > _size.height / 3;
    if (!steady) return;
    anchor = candidate;
    _lastChange = _pointer;
    unawaited(HapticFeedback.selectionClick());
    notifyListeners();
  }

  /// Whether, with the note at [candidate], its slot would be under [local].
  bool _slotUnderPointer(RenderMasonry grid, Anchor candidate, Offset local) {
    final ts = grid.targets;
    final tags = {for (final t in ts) t.box: t.data.tag};
    final mine = ts.firstWhere((t) => t.data.tag == id).box;
    final boxes = [for (final t in ts) t.box]..remove(mine);
    int indexOf(String tag) => boxes.indexWhere((b) => tags[b] == tag);
    final at = candidate.before != null
        ? indexOf(candidate.before!)
        : candidate.pinned
        ? indexOf(othersHeader) // the pinned section ends where Others begins
        : -1;
    boxes.insert(at < 0 ? boxes.length : at, mine);
    return grid.preview(boxes)[boxes.indexOf(mine)].contains(local);
  }

  /// Flies the lifted card into its slot, then lets go of it.
  void _settle(VoidCallback? then) {
    phase = DragPhase.dropping;
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lift?.drop(() {
      _overlay?.remove();
      _overlay = null;
      final finished = id;
      then?.call();
      id = null;
      phase = DragPhase.idle;
      // the board keeps showing the new order until the library has it
      if (finished != null) notifyListeners();
    });
    _overlay?.markNeedsBuild();
  }

  /// The slot's place on screen now (it may still be gliding).
  Rect? get _slotRect {
    final grid = _grid;
    if (grid == null || !grid.attached) return null;
    for (final t in grid.targets) {
      if (t.data.tag == id) return grid.localToGlobal(t.target.topLeft) & t.target.size;
    }
    return null;
  }

  Widget _buildOverlay(BuildContext context) =>
      _LiftedCard(drag: this, child: id == null ? const SizedBox.shrink() : cardFor(id!));

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _overlay?.remove();
    _scroller?.stopAutoScroll();
    super.dispose();
  }
}

/// The card in the air: lifted on a spring (a little larger, a deeper
/// shadow), following the pointer, then flown into its slot.
class _LiftedCard extends StatefulWidget {
  const _LiftedCard({required this.drag, required this.child});
  final BoardDrag drag;
  final Widget child;

  @override
  State<_LiftedCard> createState() => _Lift();
}

class _Lift extends State<_LiftedCard> with TickerProviderStateMixin {
  late final _lift = AnimationController.unbounded(vsync: this, value: 0);
  late final _fly = AnimationController.unbounded(vsync: this, value: 0);
  Rect? _from;
  VoidCallback? _landed;

  bool get _still => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.drag._lift = this;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_still) {
        _lift.value = 1;
      } else {
        unawaited(_lift.animateWith(SpringSimulation(Springs.standardFastSpatial, 0, 1, 0)));
      }
    });
  }

  void drop(VoidCallback landed) {
    final d = widget.drag;
    _from = (d._pointer - d._grab) & d._size;
    _landed = landed;
    if (_still) {
      landed();
      return;
    }
    unawaited(_lift.animateWith(SpringSimulation(Springs.standardFastSpatial, _lift.value, 0, 0)));
    _fly.animateWith(SpringSimulation(Springs.expressiveDefaultSpatial, 0, 1, 0)).whenCompleteOrCancel(() {
      final done = _landed;
      _landed = null;
      done?.call();
    });
  }

  @override
  void dispose() {
    if (widget.drag._lift == this) widget.drag._lift = null;
    _lift.dispose();
    _fly.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_lift, _fly, widget.drag]),
    builder: (context, child) {
      final d = widget.drag;
      final held = (d._pointer - d._grab) & d._size;
      final slot = d._slotRect;
      final rect = _from != null && slot != null ? Rect.lerp(_from, slot, _fly.value)! : held;
      final lift = _lift.value.clamp(0.0, 1.2);
      final radius = Theme.of(context).cardTheme.shape is RoundedRectangleBorder
          ? (Theme.of(context).cardTheme.shape! as RoundedRectangleBorder).borderRadius
          : BorderRadius.circular(12);
      return Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: IgnorePointer(
              child: Transform.scale(
                scale: 1 + 0.04 * lift,
                child: PhysicalModel(
                  color: Colors.transparent,
                  elevation: 6 * lift,
                  shadowColor: Theme.of(context).colorScheme.shadow,
                  borderRadius: radius.resolve(Directionality.of(context)),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      );
    },
    child: widget.child,
  );
}

/// The board's drag gestures, around its grid: a mouse press that travels,
/// or a long press on touch and stylus.
class BoardGestures extends StatefulWidget {
  const BoardGestures({super.key, required this.drag, required this.enabled, required this.child});
  final BoardDrag drag;
  final bool enabled;
  final Widget child;

  @override
  State<BoardGestures> createState() => _BoardGesturesState();
}

class _BoardGesturesState extends State<BoardGestures> {
  Offset? _down;
  int? _mouse;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final drag = widget.drag;
    return Listener(
      // the mouse: lift after 6px of travel with the primary button held
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryButton) {
          _down = e.position;
          _mouse = e.pointer;
        }
      },
      onPointerMove: (e) {
        if (e.pointer != _mouse) return;
        if (!drag.active && _down != null && (e.position - _down!).distance > 6) {
          if (!drag.lift(_down!, context)) _down = null;
        }
        if (drag.active) drag.move(e.position);
      },
      onPointerUp: (e) {
        if (e.pointer == _mouse && drag.active) drag.drop();
        _down = _mouse = null;
      },
      onPointerCancel: (e) {
        if (e.pointer == _mouse && drag.active) drag.cancel();
        _down = _mouse = null;
      },
      child: RawGestureDetector(
        gestures: {
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              supportedDevices: {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus},
            ),
            (r) {
              r
                ..onLongPressStart = ((d) {
                  drag.lift(d.globalPosition, context);
                })
                ..onLongPressMoveUpdate = ((d) {
                  drag.move(d.globalPosition);
                })
                ..onLongPressEnd = ((_) {
                  drag.drop();
                })
                ..onLongPressCancel = drag.cancel;
            },
          ),
        },
        child: widget.child,
      ),
    );
  }
}
