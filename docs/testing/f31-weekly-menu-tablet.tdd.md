# F31 weekly menu tablet acceptance

This slice exposes the existing encrypted weekly-menu contract through the
authenticated Android tablet client. It does not close F31: recipe/menu editing,
the confirmed Home Assistant shopping-list write, physical tablet acceptance,
and full CI evidence remain open. Official progress therefore stays at
**22/125 (17.6%)** and **0/63**.

Exactly three user acceptance criteria are in scope:

1. A verified, signed-in Core account can open a seven-day weekly menu from the
   Core home. The route binds the exact runtime identity, account generation,
   interaction epoch and Core/home context; account, source, route or lifecycle
   retirement clears data and rejects a late response.
2. Each planned meal shows its recipe, meal slot and servings, and opens an
   EN/TR shopping preview with quantities scaled from the recipe's base
   servings. This slice performs no shopping-list write, so review cannot be
   mistaken for a completed Home Assistant action.
3. The Cupertino tablet layout is usable at 600 and 1280 logical pixels with
   2x text, keeps the shopping action at least 48dp high, scrolls without
   overflow, and preserves the existing protected Core-account flow after the
   new home entry is added.

## TDD evidence

The RED phase exposed a horizontal overflow in the first trailing-button layout
and the existing narrow-tablet logout test could no longer reach its account
action after the new home entry. The GREEN phase uses a vertical, full-width
meal action and scrolls to the protected account entry. Focused widget, real
loopback Core contract and logout regression tests pass in both locales and
tablet widths, and targeted Flutter analysis reports no issues.

RED `32f27c19` exposed a loaded menu remaining visible while its route became
inactive. The screen now retires the prior snapshot on route/TickerMode and
lifecycle changes, then performs a fresh read on activation; late results remain
bound to the current operation.
