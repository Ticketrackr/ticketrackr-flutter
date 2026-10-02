// The Help button's badge while support is closed (sdks/protocol, section 7): the token support hands over, kept with
// shared_preferences across launches, and the count asked of TicketRackr with it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

/// The customer's unread replies, asked of TicketRackr now, for a badge of your own (a tab bar, a menu): the number,
/// or null when it isn't known (support hasn't been opened in this app yet, it was last opened over 30 days ago, or
/// your app's user signed out). Each answer also updates the Help button's badge.
Future<int?> ticketRackrUnreadCount() => UnreadBadge.count();

/// Forgets the customer's unread badge. Call it when your app's user signs out, so the next person on the device
/// doesn't see their count.
Future<void> ticketRackrSignOut() => UnreadBadge.signOut();

/// The token support handed over, the support page's origin it's used at, and the last count known.
@immutable
class KeptUnread {
  const KeptUnread({required this.origin, required this.token, required this.expiresAt, this.count});

  final String origin;
  final String token;

  /// Milliseconds since 1970.
  final int expiresAt;
  final int? count;

  KeptUnread withCount(int? count) => KeptUnread(origin: origin, token: token, expiresAt: expiresAt, count: count);

  String encode() => jsonEncode({'origin': origin, 'token': token, 'expiresAt': expiresAt, 'count': count});

  /// What was kept, or null for nothing or anything damaged.
  static KeptUnread? decode(String? raw) {
    if (raw == null) return null;
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (value is! Map) return null;
    final origin = value['origin'], token = value['token'], expiresAt = value['expiresAt'], count = value['count'];
    if (origin is! String || SupportOrigin.of(origin) != origin) return null;
    if (token is! String || !SupportUnreadToken.pattern.hasMatch(token) || expiresAt is! int) return null;
    return KeptUnread(origin: origin, token: token, expiresAt: expiresAt, count: count is int && count >= 0 ? count : null);
  }
}

/// Asks for the count: the answer's status and body.
typedef UnreadFetch = Future<(int, String)> Function(UnreadRequest request);

/// The Help button's badge while support is closed: the latest token support handed over and the last count, kept
/// across launches and shared by every Help button in the app.
abstract final class UnreadBadge {
  static const _key = 'ticketrackr.support.unread';
  static const _timeout = Duration(seconds: 10);

  /// The count every Help button shows: the last one known, or null when none is.
  static final shown = ValueNotifier<int?>(null);

  /// How TicketRackr is asked. Tests replace it.
  @visibleForTesting
  static UnreadFetch fetch = _ask;

  /// Milliseconds since 1970. Tests replace it.
  @visibleForTesting
  static int Function() now = _now;

  static KeptUnread? _kept;
  static Future<void>? _loading;
  // The count support last reported, even before its token arrived (the page sends the count first).
  static int? _reported;
  // Every automatic check in the app (a Help button appearing, the app coming back), counting only checks that ask.
  static UnreadGuard _guard = UnreadGuard();
  // Support views showing: their own events keep the badge current, so automatic checks wait.
  static int _supportShown = 0;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// Keeps the token from an `unread-token` event with the support page's [origin], replacing any earlier one.
  static Future<void> keep(String origin, String token, int expiresAt) async {
    final current = await _read();
    await _write(KeptUnread(origin: origin, token: token, expiresAt: expiresAt, count: _reported ?? current?.count));
  }

  /// The count support reported while open.
  static Future<void> note(int count) async {
    _reported = count;
    final current = await _read();
    if (current != null) {
      await _write(current.withCount(count));
    } else {
      shown.value = count;
    }
  }

  /// The last count known, without asking: null without a current token.
  static Future<int?> last() async {
    final kept = await _read();
    return kept != null && SupportUnreadToken.current(kept.expiresAt, now()) ? kept.count : null;
  }

  /// Asks TicketRackr now: the count, or null when it isn't known. A refused or expired token is forgotten.
  static Future<int?> count() async {
    final kept = await _read();
    if (kept == null) return null;
    if (!SupportUnreadToken.current(kept.expiresAt, now())) {
      await _write(null);
      return null;
    }
    UnreadAnswer answer;
    try {
      final (status, body) = await fetch(UnreadRequest(kept.origin, kept.token));
      answer = UnreadAnswer.read(status, body);
    } catch (_) {
      // No connection, or no answer in time: ask again next time.
      answer = const UnreadKeep();
    }
    final current = _kept;
    // Support handed over a new token while this one was asked about, or the app's user signed out: that stands.
    if (current == null || current.token != kept.token) return last();
    switch (answer) {
      case UnreadCount(:final count):
        await _write(current.withCount(count));
        return count;
      case UnreadForget():
        await _write(null);
        return null;
      case UnreadKeep():
        return current.count;
    }
  }

  /// An automatic check (a Help button appearing, the app coming back): at most once a minute in all, counting only
  /// checks that ask, and not while support is open (its own events keep the badge current).
  static Future<int?> refresh() async {
    final kept = await _read();
    if (kept == null || _supportShown > 0) return last();
    // An expired token is forgotten without asking.
    if (!SupportUnreadToken.current(kept.expiresAt, now())) return count();
    return _guard.allow(now()) ? count() : last();
  }

  /// Forgets the token and the count: the app's user signed out.
  static Future<void> signOut() async {
    _reported = null;
    await _read();
    await _write(null);
  }

  /// A support view started showing.
  static void supportOpened() => _supportShown++;

  /// A support view went away.
  static void supportClosed() => _supportShown--;

  /// Forgets what's in memory, as on a new launch.
  @visibleForTesting
  static void reset() {
    _kept = null;
    _loading = null;
    _reported = null;
    _guard = UnreadGuard();
    _supportShown = 0;
    shown.value = null;
    fetch = _ask;
    now = _now;
  }

  /// What was kept, read from storage once per launch.
  static Future<KeptUnread?> _read() async {
    await (_loading ??= _load());
    return _kept;
  }

  static Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _kept = KeptUnread.decode(preferences.getString(_key));
    } catch (error) {
      // No storage here: the badge works in memory, for this launch.
      debugPrint("TicketRackr: the unread badge can't be kept: $error");
    }
    final kept = _kept;
    shown.value = kept != null && SupportUnreadToken.current(kept.expiresAt, now()) ? kept.count : null;
  }

  /// Keeps [next], or forgets with null, and every Help button shows its count. Read first.
  static Future<void> _write(KeptUnread? next) async {
    _kept = next;
    shown.value = next?.count;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (next == null) {
        await preferences.remove(_key);
      } else {
        await preferences.setString(_key, next.encode());
      }
    } catch (error) {
      // Storage refused (a full disk): the badge still works in memory.
      debugPrint("TicketRackr: the unread badge can't be kept: $error");
    }
  }

  /// The request with dart:io, answered within 10 seconds: no cookies, and no redirects, so the token goes only to the
  /// support page's origin.
  static Future<(int, String)> _ask(UnreadRequest request) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    Future<(int, String)> exchange() async {
      final ask = await client.getUrl(request.url);
      ask.followRedirects = false;
      ask.headers.set(HttpHeaders.authorizationHeader, request.authorization);
      ask.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await ask.close();
      return (response.statusCode, await response.transform(utf8.decoder).join());
    }

    try {
      return await exchange().timeout(_timeout);
    } finally {
      // Also ends a request that wasn't answered in time.
      client.close(force: true);
    }
  }
}
