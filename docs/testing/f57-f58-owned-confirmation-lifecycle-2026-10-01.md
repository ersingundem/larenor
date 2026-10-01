# F57/F58 route-owned confirmation lifecycle — 2026-10-01

The room-presence and e-paper management screens open a Cupertino confirmation
dialog after Core has returned an exact preview. Their production route wrappers
subscribe to `ModalRoute` dependencies so foreign navigation, window loss,
account replacement and Core/home drift retire the route-owned transport.

The original implementation treated its own confirmation dialog like foreign
navigation. When the dialog became current, `didChangeDependencies` scheduled a
current-authority check on the covered parent route. The next frame disposed the
controller and transport while the confirmation remained visible. A user could
then press Confirm, but the disposed screen epoch prevented the Core confirmation
request. Synchronous `Navigator.pop` behavior was not the defect.

The first repair used a boolean confirmation-visibility lease. A second RED
regression showed that the boolean admitted any foreign route pushed above the
dialog. A captured Confirm callback could then pop that foreign route because
it addressed the navigator's current route rather than the owned dialog.

The final repair records the exact `CupertinoDialogRoute` before pushing it.
The parent may remain eligible only while that exact route is current or is
finishing its reverse transition. Confirm and Cancel act only while that route
is current and remove that exact route; after completion and an end-of-frame
parent-current check, Confirm may call Core. Authority drift removes only the
owned dialog and retires the controller, so callbacks captured before a foreign
cover are inert, the foreign route remains current, and pending state is
cleared. Release also carries the exact dialog identity; a delayed `finally`
from an old screen cannot clear a newer dialog lease. Removing the real parent
route while its dialog is visible safely removes that exact dialog without a
Navigator lock failure. Every other authority condition remains mandatory:
provider container,
runtime identity, account generation, home interaction epoch,
foreground/focus/window policy, verified Core source, active interaction,
authenticated context, password state and ticker state. Normal foreign
navigation still retires and recreates the room-presence runtime; account
sign-out and switching the selected home source still retire the corresponding
runtime.

The production-route regressions first failed with zero confirmation calls for
both features. After the repair, 21 focused tests pass and prove exact confirm
plus readback through the real route, account gateway and HTTP parser
composition, while retaining the existing management-screen coverage. They also
cover a foreign route pushed while the owned dialog is visible, inert captured
Confirm and Cancel callbacks, exact pending-state cleanup, foreign-route
retirement/recreation, parent-route removal, account retirement and home-source
retirement. Scoped analysis of the four production files and two new route tests
reports no issues.

Focused command:

```sh
flutter test --no-pub \
  test/features/room_presence/room_presence_management_test.dart \
  test/features/room_presence/room_presence_route_confirmation_lifecycle_test.dart \
  test/features/epaper/epaper_management_test.dart \
  test/features/epaper/epaper_route_confirmation_lifecycle_test.dart

flutter analyze --no-fatal-infos \
  lib/features/room_presence/presentation/room_presence_route.dart \
  lib/features/room_presence/presentation/room_presence_management_screen.dart \
  lib/features/epaper/presentation/epaper_management_route.dart \
  lib/features/epaper/presentation/epaper_management_screen.dart \
  test/features/room_presence/room_presence_route_confirmation_lifecycle_test.dart \
  test/features/epaper/epaper_route_confirmation_lifecycle_test.dart
```

This is a software lifecycle proof. Physical room sensors, OpenEPaperLink
bridges and tag display delivery remain separate provider/device acceptance.
