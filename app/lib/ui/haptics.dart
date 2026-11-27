import 'dart:async';

import 'package:flutter/services.dart';

/// Touch feedback, as Material asks of a phone app (nothing happens where
/// there is no haptic motor): a tick for a choice made or a state flipped,
/// a bump for something done to a note.
void tick() => unawaited(HapticFeedback.selectionClick());

void bump() => unawaited(HapticFeedback.lightImpact());

/// A card picked up to move.
void pickUp() => unawaited(HapticFeedback.mediumImpact());
