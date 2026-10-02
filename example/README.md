# TicketRackr support example

Shows both ways in: a Help button (`SupportButton`) and support inside a screen of the app's (`TicketRackrSupport`).
It asks for support links at `SUPPORT_LINK_URL` (`flutter run --dart-define=SUPPORT_LINK_URL=…`), by default
`http://localhost:4390/support-link`: TicketRackr's `scripts/embedded-support-test-host.mjs`, reached from a phone
through `adb reverse`.
