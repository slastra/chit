import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// How long a checked item stays in place, checked and struck through,
/// before it folds away: long enough to see what happened.
const checkBeat = Duration(milliseconds: 350);

/// A list row that folds open when it arrives ([enter]) and folds shut when
/// [leaving] turns true, then calls [onGone]. Material's emphasized easing:
/// decelerating in (medium, 300ms), accelerating out (short, 200ms). With
/// reduced motion it simply appears and goes.
class Fold extends StatefulWidget {
  const Fold({super.key, required this.child, this.leaving = false, this.enter = false, this.onGone});

  final Widget child;
  final bool leaving;
  final bool enter;
  final VoidCallback? onGone;

  @override
  State<Fold> createState() => _FoldState();
}

class _FoldState extends State<Fold> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: Durations.medium2,
    reverseDuration: Durations.short4,
    value: widget.enter ? 0 : 1,
  );
  late final _size = CurvedAnimation(
    parent: _c,
    curve: Easing.emphasizedDecelerate,
    reverseCurve: Easing.emphasizedAccelerate,
  );

  bool get _still => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    if (widget.enter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _still ? _c.value = 1 : unawaited(_c.forward());
      });
    }
  }

  @override
  void didUpdateWidget(Fold old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      if (_still) {
        _c.value = 0;
        widget.onGone?.call();
      } else {
        unawaited(_c.reverse().then((_) => widget.onGone?.call()));
      }
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _size,
    alignment: Alignment.topCenter,
    child: FadeTransition(opacity: _c, child: widget.child),
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
