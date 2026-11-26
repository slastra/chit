import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// How long a checked item stays in place, checked and struck through,
/// before it folds away: long enough to see what happened.
const checkBeat = Duration(milliseconds: 350);

/// A list row that folds open when it arrives ([enter]) and folds shut when
/// [leaving] turns true, then calls [onGone]. Material 3 Expressive motion:
/// the height moves on the standard spatial spring and the fade on the
/// standard effects spring (springs, not durations). With reduced motion it
/// simply appears and goes.
class Fold extends StatefulWidget {
  const Fold({super.key, required this.child, this.leaving = false, this.enter = false, this.onGone});

  final Widget child;
  final bool leaving;
  final bool enter;
  final VoidCallback? onGone;

  @override
  State<Fold> createState() => _FoldState();
}

class _FoldState extends State<Fold> with TickerProviderStateMixin {
  late final _size = AnimationController.unbounded(vsync: this, value: widget.enter ? 0 : 1);
  late final _fade = AnimationController.unbounded(vsync: this, value: widget.enter ? 0 : 1);

  bool get _still => MediaQuery.disableAnimationsOf(context);

  Future<void> _to(double target) {
    if (_still) {
      _size.value = target;
      _fade.value = target;
      return Future.value();
    }
    unawaited(_fade.animateWith(SpringSimulation(Springs.standardDefaultEffects, _fade.value, target, 0)));
    return _size.animateWith(SpringSimulation(Springs.standardDefaultSpatial, _size.value, target, _size.velocity));
  }

  @override
  void initState() {
    super.initState();
    if (widget.enter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_to(1));
      });
    }
  }

  @override
  void didUpdateWidget(Fold old) {
    super.didUpdateWidget(old);
    if (widget.leaving == old.leaving) return;
    // either way: folding away (then gone), or unfolding again
    if (widget.leaving) {
      unawaited(
        _to(0).then((_) {
          if (mounted && widget.leaving) widget.onGone?.call();
        }),
      );
    } else {
      unawaited(_to(1));
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_size, _fade]),
    builder: (context, child) => ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: _size.value.clamp(0.0, 1.0),
        child: Opacity(opacity: _fade.value.clamp(0.0, 1.0), child: child),
      ),
    ),
    child: widget.child,
  );
}

/// Checks an item off with a beat to see it: the box fills and the text is
/// struck at once, the row folds away after [checkBeat], and only then does
/// [commit] send the edit (which moves the item to the checked list).
/// Holds the rows on their way out.
final class CheckOff {
  CheckOff(this._refresh);

  final VoidCallback _refresh;
  final _checking = <String>{}; // shown checked, waiting out the beat
  final _leaving = <String>{}; // folding away
  final _targets = <String, bool>{}; // where each is going: checked or not
  final _arrived = <String, bool>{}; // moved by us: fold in where they land
  final _timers = <Timer>[];

  /// Shown checked although the replica does not say so yet.
  bool showsChecked(String id) => _checking.contains(id) || _leaving.contains(id);
  bool isLeaving(String id) => _leaving.contains(id);

  /// Whether a row just landed in the section for [checked] after being
  /// moved there, to fold it in; true once.
  bool takeArrival(String id, bool checked) {
    if (_arrived[id] != checked) return false;
    _arrived.remove(id);
    return true;
  }

  /// Starts moving [id] to the checked list ([target] true) or back.
  void start(String id, {required bool target, required bool still, required VoidCallback commit}) {
    if (showsChecked(id)) return;
    unawaited(HapticFeedback.selectionClick());
    if (still) {
      commit();
      return;
    }
    _checking.add(id);
    _targets[id] = target;
    _refresh();
    _timers.add(
      Timer(checkBeat, () {
        _checking.remove(id);
        _leaving.add(id);
        _refresh();
      }),
    );
    _commits[id] = commit;
  }

  final _commits = <String, VoidCallback>{};

  /// The row finished folding away: send the edit, and fold it in where it
  /// lands.
  void gone(String id) {
    _leaving.remove(id);
    if (_targets.remove(id) case final target?) _arrived[id] = target;
    _commits.remove(id)?.call();
    _refresh();
  }

  /// Sends whatever is still waiting (the page is closing).
  void flush() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    for (final commit in _commits.values) {
      commit();
    }
    _commits.clear();
  }
}
