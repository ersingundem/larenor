# B51 settings panes tablet acceptance

Progress authority: **17/125 (13.6%) delivery, 0/63 (0.0%) research**.

| Acceptance area | Automated evidence | Boundary |
| --- | --- | --- |
| Settings home and panes | EN/TR at 600/1200 logical pixels with 2x text verifies the shared pane chrome, headings, 48dp actions, keyboard activation, and the Display, Security, and Integrations destinations. | Final Huawei MatePad, DeX, switch-control, and TalkBack traversal remain physical-device release checks. |
| Account, security, and integration transitions | PIN gate tests expire old dialog callbacks across idle/background changes; pane tests open the real PIN editor and unified Media Hub rather than test-only substitutes. | Provider credentials and live service mutations require configured test accounts and remain outside screenshot/widget authority. |
| Tablet navigation and back | Narrow navigation preserves pane then app back order; wide navigation now routes the Android/DeX system back event through the detail navigator before leaving Settings. | OEM gesture-edge behavior and hardware keyboard Back keys remain physical-device release checks. |
