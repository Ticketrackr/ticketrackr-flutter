// The Help button's badge while support is closed (sdks/protocol, section 7): what's kept, when TicketRackr is asked,
// and what each answer does.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketrackr_support/src/protocol.dart';
import 'package:ticketrackr_support/src/unread_badge.dart';
import 'package:ticketrackr_support/ticketrackr_support.dart';

const token = 'trk_unread_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ';
const newer = 'trk_unread_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';
const origin = 'https://ticketrackr.com';
const key = 'ticketrackr.support.unread';
const day = 24 * 60 * 60 * 1000;

/// Real requests, even after the widget tests' binding has replaced them.
class _RealRequests extends HttpOverrides {}

void main() {
  late List<UnreadRequest> asked;
  late Future<(int, String)> Function() answer;
  var clock = 0;

  /// A new launch: nothing in memory, only what was kept.
  void launch({bool realRequests = false}) {
    UnreadBadge.reset();
    UnreadBadge.now = () => clock;
    if (!realRequests) {
      UnreadBadge.fetch = (request) {
        asked.add(request);
        return answer();
      };
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    asked = [];
    answer = () async => (200, '{"unread": 2}');
    clock = DateTime.utc(2026, 10, 2).millisecondsSinceEpoch;
    launch();
  });

  Future<Map<String, dynamic>?> kept() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  String keptValue({String keptToken = token, int? expiresAt, int? count}) =>
      jsonEncode({'origin': origin, 'token': keptToken, 'expiresAt': expiresAt ?? clock + day, 'count': count});

  test('a token is kept with its origin, and a new one replaces it', () async {
    await UnreadBadge.keep(origin, token, clock + day);
    expect(await kept(), {'origin': origin, 'token': token, 'expiresAt': clock + day, 'count': null});
    await UnreadBadge.note(3);
    await UnreadBadge.keep('http://localhost:3219', newer, clock + 2 * day);
    expect(await kept(), {'origin': 'http://localhost:3219', 'token': newer, 'expiresAt': clock + 2 * day, 'count': 3});
  });

  test('a count reported before its token is kept with it', () async {
    // The page sends the count first, then fetches the token.
    await UnreadBadge.note(4);
    expect(await kept(), isNull);
    expect(UnreadBadge.shown.value, 4);
    await UnreadBadge.keep(origin, token, clock + day);
    expect((await kept())!['count'], 4);
    launch();
    expect(await UnreadBadge.last(), 4);
    expect(UnreadBadge.shown.value, 4);
  });

  test('the count is asked for with the kept token, and kept', () async {
    await UnreadBadge.keep(origin, token, clock + day);
    expect(await ticketRackrUnreadCount(), 2);
    expect(asked.single.url.toString(), 'https://ticketrackr.com/api/support/unread');
    expect(asked.single.authorization, 'Bearer $token');
    expect((await kept())!['count'], 2);
    expect(UnreadBadge.shown.value, 2);
  });

  test('a refused token is forgotten, and the badge with it', () async {
    await UnreadBadge.keep(origin, token, clock + day);
    await UnreadBadge.note(3);
    answer = () async => (401, '{"message": "Open support again from your application."}');
    expect(await ticketRackrUnreadCount(), isNull);
    expect(await kept(), isNull);
    expect(UnreadBadge.shown.value, isNull);
  });

  test('any other answer keeps the badge as it was', () async {
    await UnreadBadge.keep(origin, token, clock + day);
    await UnreadBadge.note(3);
    for (final reply in <Future<(int, String)> Function()>[
      () async => (503, '{}'),
      () async => (200, 'nope'),
      () async => throw const SocketException('No connection'),
    ]) {
      answer = reply;
      expect(await ticketRackrUnreadCount(), 3);
    }
    expect(await kept(), {'origin': origin, 'token': token, 'expiresAt': clock + day, 'count': 3});
  });

  test('an expired token is forgotten without asking', () async {
    await UnreadBadge.keep(origin, token, clock + 1);
    clock += 1;
    expect(await UnreadBadge.last(), isNull);
    expect(await ticketRackrUnreadCount(), isNull);
    expect(asked, isEmpty);
    expect(await kept(), isNull);
  });

  test('without a token nothing is asked', () async {
    expect(await ticketRackrUnreadCount(), isNull);
    expect(await UnreadBadge.refresh(), isNull);
    expect(asked, isEmpty);
  });

  test('signing out forgets the token and the count', () async {
    await UnreadBadge.note(5);
    await UnreadBadge.keep(origin, token, clock + day);
    await ticketRackrSignOut();
    expect(await kept(), isNull);
    expect(UnreadBadge.shown.value, isNull);
    expect(await ticketRackrUnreadCount(), isNull);
    expect(asked, isEmpty);
    // The next person's token doesn't get the count reported before signing out.
    await UnreadBadge.keep(origin, newer, clock + day);
    expect((await kept())!['count'], isNull);
  });

  test("what was kept is read on the next launch, and anything damaged isn't", () async {
    SharedPreferences.setMockInitialValues({key: keptValue(count: 6)});
    launch();
    expect(await UnreadBadge.last(), 6);
    expect(UnreadBadge.shown.value, 6);
    for (final damaged in [
      'nope',
      '[]',
      jsonEncode({'origin': 'ticketrackr.com', 'token': token, 'expiresAt': clock + day, 'count': 6}),
      keptValue(keptToken: 'trk_portal_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ', count: 6),
    ]) {
      SharedPreferences.setMockInitialValues({key: damaged});
      launch();
      expect(await UnreadBadge.last(), isNull, reason: damaged);
      expect(await ticketRackrUnreadCount(), isNull, reason: damaged);
    }
    expect(asked, isEmpty);
  });

  test('automatic checks ask at most once a minute, only with a token, and not while support is open', () async {
    // Nothing kept: nothing to ask, and the minute isn't used up.
    expect(await UnreadBadge.refresh(), isNull);
    await UnreadBadge.keep(origin, token, clock + day);
    expect(await UnreadBadge.refresh(), 2);
    expect(asked, hasLength(1));
    answer = () async => (200, '{"unread": 7}');
    clock += 59999;
    expect(await UnreadBadge.refresh(), 2);
    expect(asked, hasLength(1));
    clock += 1;
    UnreadBadge.supportOpened();
    expect(await UnreadBadge.refresh(), 2);
    expect(asked, hasLength(1));
    UnreadBadge.supportClosed();
    expect(await UnreadBadge.refresh(), 7);
    expect(asked, hasLength(2));
    // The app asking for its own badge isn't held back.
    expect(await ticketRackrUnreadCount(), 7);
    expect(asked, hasLength(3));
  });

  test('a token handed over while asking stands', () async {
    await UnreadBadge.keep(origin, token, clock + day);
    final reply = Completer<(int, String)>();
    answer = () => reply.future;
    final asking = ticketRackrUnreadCount();
    await Future<void>.delayed(Duration.zero);
    expect(asked, hasLength(1));
    // Support opens meanwhile: a count, then a new token. The old token's refusal doesn't forget the new one.
    await UnreadBadge.note(1);
    await UnreadBadge.keep(origin, newer, clock + day);
    reply.complete((401, '{}'));
    expect(await asking, 1);
    expect(await kept(), {'origin': origin, 'token': newer, 'expiresAt': clock + day, 'count': 1});
  });

  test('the request goes to the support page with the token, without cookies or redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String>[];
    server.listen((request) {
      seen.add('${request.method} ${request.uri} ${request.headers.value('authorization')} ${request.headers.value('cookie')}');
      if (seen.length == 1) {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"unread": 5}');
      } else {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('location', 'http://127.0.0.1:${server.port}/elsewhere');
      }
      unawaited(request.response.close());
    });
    launch(realRequests: true);
    await UnreadBadge.keep('http://127.0.0.1:${server.port}', token, clock + day);
    expect(await HttpOverrides.runWithHttpOverrides(ticketRackrUnreadCount, _RealRequests()), 5);
    expect(seen, ['GET /api/support/unread Bearer $token null']);
    // A redirect isn't followed: the badge stays as it was.
    expect(await HttpOverrides.runWithHttpOverrides(ticketRackrUnreadCount, _RealRequests()), 5);
    expect(seen, hasLength(2));
  });

  group('the Help button', () {
    Widget app(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));
    Future<String> getSupportLink() async => 'https://ticketrackr.com/support#code=unused';

    void comeBack(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('shows the kept count, then asks when it appears and when the app comes back', (tester) async {
      SharedPreferences.setMockInitialValues({key: keptValue(count: 3)});
      launch();
      answer = () async => (503, '{}');
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(SupportButton(getSupportLink: getSupportLink)));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('Help, 3 unread'), findsOneWidget);
      expect(asked, hasLength(1));

      // Back within the minute: not asked.
      comeBack(tester);
      await tester.pump();
      expect(asked, hasLength(1));

      // Back a minute later: the customer has read their replies, and the badge goes.
      answer = () async => (200, '{"unread": 0}');
      clock += 60000;
      comeBack(tester);
      await tester.pump();
      await tester.pump();
      expect(asked, hasLength(2));
      expect(find.text('3'), findsNothing);
      expect(find.bySemanticsLabel('Help'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('shows what support reports, like every other Help button', (tester) async {
      await tester.pumpWidget(app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [SupportButton(getSupportLink: getSupportLink), SupportButton(getSupportLink: getSupportLink, label: 'Contact us')],
      )));
      await tester.pump();
      expect(asked, isEmpty);
      await UnreadBadge.note(2);
      await tester.pump();
      expect(find.text('2'), findsNWidgets(2));
      await UnreadBadge.note(0);
      await tester.pump();
      expect(find.text('2'), findsNothing);
      expect(find.text('0'), findsNothing);
    });
  });
}
