import 'package:flutter/cupertino.dart';

/// Single iOS-style theme; Cupertino's dynamic colors (e.g.
/// [CupertinoColors.systemBackground]) resolve to light/dark automatically
/// from the platform brightness, so no separate light/dark variant is
/// needed here.
const larenorCupertinoTheme = CupertinoThemeData(
  primaryColor: CupertinoColors.activeBlue,
);
