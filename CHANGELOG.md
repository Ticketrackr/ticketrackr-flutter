## 0.3.0

- `SupportOptions(ticket: …)`: opens one of the customer's requests, by its id (`ticket.id` from the
  `ticket.message.created` webhook), for example when the customer taps a notification about a reply. Another
  customer's request isn't opened; support shows their own requests instead.
- The Help button's badge counts unread replies while support is closed too: support hands the app a token that reads
  only that count, kept with `shared_preferences`, and the button asks TicketRackr with it when it appears and when the
  app comes back to the foreground, at most once a minute.
- `ticketRackrUnreadCount()`: the count, for a badge of your own (a tab bar, a menu).
- `ticketRackrSignOut()`: forgets the badge. Call it when your app's user signs out.

## 0.2.0

- First release: `SupportButton`, `TicketRackrSupport` and `showTicketRackrSupport` for iOS and Android, following
  TicketRackr's embedded support protocol.
