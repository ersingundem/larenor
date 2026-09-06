import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Evaluate the condition only for the single current mounted fixture target.
/// Condition failures must propagate; this is not a general exception catcher.
bool singleElementReady(Finder finder, bool Function(Element) condition) =>
    condition(finder.evaluate().single);
