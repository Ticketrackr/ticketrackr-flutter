// The protocol cases every TicketRackr SDK passes (sdks/protocol/conformance.json, copied here).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ticketrackr_support/src/protocol.dart';

void main() {
  final cases = jsonDecode(File('test/conformance.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String key) => (cases[key] as List).cast<Map<String, dynamic>>();

  test('the address support is shown at', () {
    for (final item in list('frameUrl')) {
      final options = item['options'] as Map<String, dynamic>;
      final url = SupportAddress.frameUrl(
        item['link'] as String,
        options: SupportOptions(
          requestType: options['requestType'] as String?,
          subject: options['subject'] as String?,
          fields: (options['fields'] as Map<String, dynamic>? ?? {}).cast<String, String>(),
          language: options['language'] as String?,
          ticket: options['ticket'] as String?,
        ),
        closable: options['closable'] as bool? ?? false,
        edges: options['edges'] as bool? ?? false,
        load: options['load'] as int? ?? 0,
      );
      final expect_ = item['expect'] as Map<String, dynamic>;
      final name = item['name'] as String;
      final port = url.hasPort ? ':${url.port}' : '';
      expect('${url.scheme}://${url.host}$port${url.path}', expect_['base'], reason: name);
      expect(url.fragment, expect_['fragment'], reason: name);
      expect(url.queryParameters, (expect_['params'] as Map<String, dynamic>).cast<String, String>(), reason: name);
    }
  });

  test('only TicketRackr support links are shown', () {
    for (final link in (cases['invalidLinks'] as List).cast<String>()) {
      expect(() => SupportAddress.frameUrl(link), throwsA(isA<SupportLinkException>()), reason: link);
    }
  });

  test("only the page's own events are read", () {
    for (final item in list('events')) {
      final data = item['data'] as String;
      final expect_ = item['expect'] as Map<String, dynamic>?;
      final expected = switch (expect_?['event']) {
        null => null,
        'ready' => const SupportReady(),
        'close' => const SupportClose(),
        'session-ended' => const SupportSessionEnded(),
        'unread' => SupportUnread(expect_!['count'] as int),
        'unread-token' => SupportUnreadToken(expect_!['token'] as String, expect_['expiresAt'] as int),
        final other => fail('an event this SDK does not know: $other'),
      };
      expect(SupportEvent.read(data), expected, reason: data);
    }
  });

  test('messages are matched by origin', () {
    for (final item in list('origins')) {
      expect(SupportOrigin.isSupport(item['url'] as String, item['origin'] as String), item['expect'], reason: item['url'] as String);
    }
  });

  test('where links go', () {
    for (final item in list('destinations')) {
      expect(SupportDestination.of(item['url'] as String, item['origin'] as String).name, item['expect'], reason: item['url'] as String);
    }
  });

  test("a session that keeps ending isn't reconnected forever", () {
    final reconnect = cases['reconnect'] as Map<String, dynamic>;
    final guard = ReconnectGuard(windowMs: reconnect['windowMs'] as int, limit: reconnect['limit'] as int);
    for (final call in (reconnect['calls'] as List).cast<Map<String, dynamic>>()) {
      expect(guard.allow(call['at'] as int), call['expect'], reason: 'at ${call['at']}');
    }
  });

  group('unread replies while support is closed', () {
    final unread = cases['unread'] as Map<String, dynamic>;
    List<Map<String, dynamic>> unreadList(String key) => (unread[key] as List).cast<Map<String, dynamic>>();

    test('are asked for at the support page with the kept token', () {
      for (final item in unreadList('requests')) {
        final request = UnreadRequest(item['origin'] as String, item['token'] as String);
        final expect_ = item['expect'] as Map<String, dynamic>;
        expect(request.url.toString(), expect_['url'], reason: item['origin'] as String);
        expect(request.authorization, expect_['authorization'], reason: item['origin'] as String);
      }
    });

    test('show the count, forget the token or keep the badge, by the answer', () {
      for (final item in unreadList('answers')) {
        final expect_ = item['expect'] as Map<String, dynamic>;
        final expected = switch (expect_['result']) {
          'count' => UnreadCount(expect_['count'] as int),
          'forget' => const UnreadForget(),
          'keep' => const UnreadKeep(),
          final other => fail('an answer this SDK does not know: $other'),
        };
        expect(UnreadAnswer.read(item['status'] as int, item['body'] as String), expected, reason: '${item['status']} ${item['body']}');
      }
    });

    test('are checked automatically at most once a minute', () {
      final cases = unread['guard'] as Map<String, dynamic>;
      final guard = UnreadGuard(intervalMs: cases['intervalMs'] as int);
      for (final call in (cases['calls'] as List).cast<Map<String, dynamic>>()) {
        expect(guard.allow(call['at'] as int), call['expect'], reason: 'at ${call['at']}');
      }
    });

    test('use a kept token only until it expires', () {
      for (final item in unreadList('expiry')) {
        expect(SupportUnreadToken.current(item['expiresAt'] as int, item['now'] as int), item['expect'], reason: 'now ${item['now']}, expires ${item['expiresAt']}');
      }
    });
  });

  test('words follow the language', () {
    expect(SupportWords.forLanguage('es').help, 'Ayuda');
    expect(SupportWords.forLanguage('pt-BR').back, 'Voltar');
    expect(SupportWords.forLanguage('ja').help, 'Help');
  });
}
