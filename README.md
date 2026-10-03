# TicketRackr Support for Flutter

Your company's TicketRackr support inside your Flutter app, without sending customers to a browser: requests and
reports with their forms, the conversation, file uploads, the AI assistant and satisfaction surveys. iOS and Android.

## Install

```bash
flutter pub add ticketrackr_support
```

On iOS, customers can attach photos and videos. If your app doesn't already say why it uses the camera, photos and
microphone, add these to `ios/Runner/Info.plist` (without them, iOS closes the app when a customer chooses Take Photo):

```xml
<key>NSCameraUsageDescription</key>
<string>Take a photo to send to support.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Choose a photo to send to support.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Record a video to send to support.</string>
```

On Android, your app needs the `INTERNET` permission in `android/app/src/main/AndroidManifest.xml` (Flutter only adds
it to debug builds).

## 1. Your server makes a support link

Your TicketRackr key stays on your server, never in the app. Add an endpoint that, for the signed-in customer:

1. calls `POST https://api.ticketrackr.com/v1/customer-sessions` with `Authorization: Bearer <your key>` and
   `{"externalCustomerId": "<your id for them>", "email": "…", "name": "…"}`, which returns a `token`;
2. calls `POST https://api.ticketrackr.com/v1/support-portal/links` with `Authorization: Bearer <that token>` and `{}`;
3. returns that link's `{"url": "…"}` to the app.

Your key is one from TicketRackr (Settings → Companies → Connect) as `clientId.clientSecret`. A sandbox key shows the
sandbox's test data; a live key, your real customers'. Use your database's id for the customer, not something that
changes like an email address.

Send the customer's email whenever you have it: support emails them there when it replies, and it's how they get
back to their requests. Without one, support asks the customer for an email and confirms it with a code before they
can start a request.

## 2. Show support

```dart
import 'package:ticketrackr_support/ticketrackr_support.dart';

Future<String> getSupportLink() async {
  final response = await yourApi.post('/support-link'); // your endpoint, with your app's sign-in
  return response.data['url'] as String;
}

// A Help button that opens support on a screen of its own:
SupportButton(getSupportLink: getSupportLink, color: Colors.pink)

// Or open it from your own button:
showTicketRackrSupport(context, getSupportLink: getSupportLink);

// Or support inside a screen of yours, filling its space:
TicketRackrSupport(getSupportLink: getSupportLink, closable: true, onClose: () => Navigator.of(context).pop())
```

## Options

| | |
| --- | --- |
| `getSupportLink` | Required. Calls your endpoint and returns the link's `url`. Called on open, and again if the session ends. |
| `options: SupportOptions(requestType: …)` | Open the form for one request type, by its key, such as a report: `'report_problem'`. |
| `options: SupportOptions(subject: …, fields: …)` | Fill in the request's subject and its type's fields (by key). |
| `options: SupportOptions(ticket: …)` | Open one of the customer's requests, by its id: `ticket.id` from the `ticket.message.created` webhook, for example when the customer taps a notification about a reply. Another customer's request isn't opened; support shows their own requests instead. |
| `options: SupportOptions(language: …)` | `en`, `es`, `fr`, `de` or `pt`. The device's language when left out. |
| `onReady`, `onUnreadChange`, `onClose` | `TicketRackrSupport`: support has loaded; the customer's unread replies, whenever the number changes; Close. |
| `closable` | `TicketRackrSupport`: show a Close button. |
| `label`, `color`, `onOpenChange` | `SupportButton`: its text (default "Help"), color, and support opening or closing. |

## Unread replies

The Help button's badge counts the customer's unread replies, even while support is closed: an agent who answers
while the customer is elsewhere in your app shows on the button. It works by itself, with no code of yours, and uses
no support link or session (sessions count toward your plan). Each time support opens, it hands your app a token that
reads only that count. The SDK keeps the token on the device (with `shared_preferences`) for 30 days, and the button
asks TicketRackr with it when it appears and when your app comes back to the foreground, at most once a minute.

For a badge of your own, like a tab bar or a menu, ask for the count when you show it:

```dart
final unread = await ticketRackrUnreadCount(); // null until support has been opened in the app
```

When your app's user signs out, forget their badge, so the next person on the device doesn't see their count:

```dart
await ticketRackrSignOut();
```

## Request types and reports

What customers can ask for (a problem report, a billing question, reporting a user) is set in TicketRackr, not in
your code: make case types with their forms in Settings → Companies → Case types, and choose which customers see in
Settings → Companies → Support page. They appear in your app right away, with no new build.

## Good to know

- Sessions renew themselves: when one ends, support asks your endpoint for a new link.
- A file the customer opens goes to Android's downloads (with a notification) and shows in Safari's in-app view on
  iOS; support stays as it was. TicketRackr pages, like the status page or a help article, open in the in-app browser
  view. Other websites, email and phone links open in their own apps.
- Support uses your brand color and logo from Settings → Companies → Support page.
- `example/` is an app that shows both ways in.
- Full guide and the API: https://ticketrackr.com/docs/support-api#embedded-support

## License

MIT: use it freely. It shows your support from TicketRackr, so it needs a TicketRackr account (sign up at
https://ticketrackr.com/signup).
