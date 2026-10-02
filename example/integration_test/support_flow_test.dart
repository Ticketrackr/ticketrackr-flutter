// The support flow in the example app on a real platform: support opens, signs in and hands over its unread token
// (which shows the platform's web view and bridge work), and the Help button counts a reply while support is closed.
//
// It needs TicketRackr running on this computer with the test company server
// (scripts/embedded-support-test-host.mjs, which also answers POST /agent-reply), then:
//   flutter test integration_test -d <simulator or device>
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ticketrackr_support/ticketrackr_support.dart';
import 'package:ticketrackr_support_example/main.dart' as example;

final host = Uri.parse(example.supportLinkEndpoint).resolve('/');

/// Support answers the customer's request, as an agent would.
Future<void> agentReply() async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(host.resolve('/agent-reply'));
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 204);
  } finally {
    client.close();
  }
}

/// Pumps frames until [done] or the time runs out (a web view never settles).
Future<void> pumpUntil(WidgetTester tester, Future<bool> Function() done, {Duration timeout = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting.');
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('support opens, and the Help button counts a reply while support is closed', (tester) async {
    await ticketRackrSignOut();
    await tester.pumpWidget(const example.ExampleApp());
    await tester.pump(const Duration(seconds: 1));
    expect(await ticketRackrUnreadCount(), isNull, reason: 'nothing to count before support has opened');

    // Opened from the Help button: signed in, it hands the app its token.
    await tester.tap(find.text('Help'));
    await pumpUntil(tester, () async => await ticketRackrUnreadCount() != null);
    final before = (await ticketRackrUnreadCount())!;
    // For a screenshot of support on this platform.
    debugPrint('SUPPORT_IS_OPEN');
    await tester.pump(const Duration(seconds: 8));

    // Closed; then support answers while the customer is elsewhere.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump(const Duration(seconds: 1));
    await agentReply();
    expect(await ticketRackrUnreadCount(), before + 1);

    // The app comes back to the foreground: the Help button shows the new count.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () async => find.text('${before + 1}').evaluate().isNotEmpty);
    debugPrint('BADGE_SHOWS_${before + 1}');
    await tester.pump(const Duration(seconds: 4));

    // Signing out forgets it.
    await ticketRackrSignOut();
    await pumpUntil(tester, () async => find.text('${before + 1}').evaluate().isEmpty);
    expect(await ticketRackrUnreadCount(), isNull);
  });
}
