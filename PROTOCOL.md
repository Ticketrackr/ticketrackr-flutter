# Embedded support protocol

How every TicketRackr support SDK shows a company's support inside its app. The support itself is one hosted page
(`/support` on TicketRackr's site); each SDK is a thin shell around it for one platform:

| Platform | SDK | Installed from |
| --- | --- | --- |
| React, Next.js | `packages/react` (`@ticketrackr/react`) | npm |
| React Native, Expo | `packages/react-native` (`@ticketrackr/react-native`) | npm |
| iOS (Swift: UIKit, SwiftUI) | `sdks/ios` (`TicketRackrSupport`) | Swift Package Manager |
| Android (Kotlin, Java) | `sdks/android` (`com.ticketrackr:support-android`) | Maven Central |
| Flutter | `sdks/flutter` (`ticketrackr_support`) | pub.dev |

Every SDK follows this document and passes [`conformance.json`](conformance.json), so they behave the same. A change to
the protocol changes this file, the test cases and every SDK together.

## 1. The support link

The app never holds a TicketRackr key. Its own server, for the signed-in customer, calls `POST /v1/customer-sessions`
with the company's key, then `POST /v1/support-portal/links` with the customer's token, and returns the link's `url`
to the app. The SDK asks for a new link through the app's callback (`getSupportLink`) each time it opens support and
each time a session ends.

A link is accepted only when it is TicketRackr's support page: `https` (or `http` on `localhost` or `127.0.0.1`, for
development), the path `/support`, and a fragment containing `code=`. Anything else is refused with an error that
names `getSupportLink`.

## 2. The address the SDK shows

The link, with these query parameters added (a later value replaces an earlier one of the same name):

| Parameter | When | Meaning |
| --- | --- | --- |
| `view=embed` | always | Support inside an app: compact, and it reports events (section 3). |
| `closable=1` | the app can close what support is shown in | Support shows a Close button, which sends `close`. |
| `edges=1` | the screen edges the page is told are the web view's own | The page keeps clear of the status bar and home indicator itself. Set on iOS always; on Android only when support fills the whole window (Android reports the window's edges wherever the view sits). |
| `load=<n>` | from the second link on | A counter, so a new link that differs only after `#` really loads. |
| `lang` | a language was chosen | `en`, `es`, `fr`, `de` or `pt`. |
| `type` | a request type was chosen | Opens the form for that request type (its key). |
| `subject` | given | Fills in the request's subject. |
| `f.<key>` | for each field given | Fills in a field. Keys match `^[a-z][a-z0-9_]{0,63}$` (others are dropped); values are cut to 500 characters. |

The fragment (`#code=…`) is kept as it is. The page redeems the code, then removes it from its address, keeping
`view`, `closable`, `edges`, `lang` and `page`.

## 3. Events from the page

The page sends events, never customer data, as a JSON string:

```json
{ "source": "ticketrackr-support", "event": "ready" }
{ "source": "ticketrackr-support", "event": "unread", "count": 2 }
```

| Event | Meaning | What the SDK does |
| --- | --- | --- |
| `ready` | Support has loaded and signed in. | Calls the app's `onReady`. |
| `unread` | The customer's unread replies (a non-negative integer `count`), whenever it changes. | Calls `onUnreadChange(count)`; the Help button shows a badge. |
| `close` | The customer pressed Close. | Calls `onClose`, or closes the sheet the SDK showed. |
| `session-ended` | The session expired or was revoked. | Gets a new link and loads it, at most twice in 30 seconds; after that it shows "Try again". |

Anything else (another `source`, another event, an `unread` without a valid count, invalid JSON) is ignored.

The page posts to whichever of these exists, so each SDK provides one:

- `window.TicketRackrSupportBridge.postMessage(json)`: native SDKs (iOS injects it in front of
  `window.webkit.messageHandlers.ticketrackrSupport`; Android adds it as a web message listener or JavaScript
  interface; Flutter adds it as a JavaScript channel).
- `window.ReactNativeWebView.postMessage(json)`: React Native.
- `window.parent.postMessage(object, "*")`: a website's frame (React).

An SDK accepts an event only when it comes from the support page's origin. Some web views give the page's address,
others (Android) only its origin, so compare origins: scheme, host and port.

## 4. Where links go

Every navigation the page starts is decided by the SDK, by its address compared with the support page's origin:

| Destination | Rule | Where it opens |
| --- | --- | --- |
| `support` | same origin, path `/support` | In support (a language change, a reload). |
| `file` | same origin, path `/api/support/tickets/<id>/attachments/<id>/download` | iOS: in a sheet over support. Android: the system's downloads. Web: the browser's download. |
| `page` | same origin, any other path (the status page, a help article) | In a sheet over support, with a Back button, so support stays as it was. |
| `outside` | another origin or scheme (`mailto:`, `tel:`), or not a valid address | In the app that handles it (the browser, mail, the phone). |

Navigations inside frames of the page load as they are. A link back to `support` from inside a sheet closes the
sheet.

A file opened with the page's cookie is redirected to a sealed link for that file that works for two minutes without
it, because Android's download manager doesn't carry the page's cookie. The SDK needs to do nothing for this.

## 5. Screens and the keyboard

- Support fills the view it is given. The Help button's sheet fills the screen.
- On Android the sheet fills the whole window, under the system bars; a window sized around the bars resizes for the
  keyboard and the web view then counts the keyboard twice.
- The web view needs DOM storage, JavaScript, inline media playback, and file uploads (the system file picker; the
  app declares camera, photo library and microphone use where the platform requires it).

## 6. Text

Each SDK's own few words (loading, failure, Try again, Help, Back, unread, downloading) come in `en`, `es`, `fr`,
`de` and `pt`, following `language`, or the device's language when none is given.
