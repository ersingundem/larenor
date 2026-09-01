/// Width at or above which the app switches to a two-pane, iPad-style
/// layout (a master list beside a detail pane) instead of pushing detail
/// screens full-screen.
///
/// Width-driven rather than orientation-driven on purpose: the app isn't
/// locked to an orientation, and a phone in landscape is still too narrow
/// for two useful panes.
const double kSplitViewMinWidth = 720;
