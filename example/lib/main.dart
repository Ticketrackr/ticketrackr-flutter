import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ticketrackr_support/ticketrackr_support.dart';

void main() => runApp(const ExampleApp());

/// Your server's endpoint that makes a support link for the signed-in customer and returns `{"url": …}` (see the
/// README). This example asks TicketRackr running on a computer (reached through adb reverse, or the simulator's
/// localhost).
const supportLinkEndpoint = String.fromEnvironment('SUPPORT_LINK_URL', defaultValue: 'http://localhost:4390/support-link');

Future<String> getSupportLink() async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(supportLinkEndpoint));
    request.headers.contentType = ContentType.json;
    request.write('{}');
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
    return body['url'] as String;
  } finally {
    client.close();
  }
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(title: 'Support Example', home: HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _log = <String>[];

  void _note(String line) => setState(() => _log.add(line));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Support Example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A Help button that opens support on a screen of its own.
            SupportButton(getSupportLink: getSupportLink, color: const Color(0xFFE11D48), onOpenChange: (open) => _note(open ? 'opened' : 'closed')),
            const SizedBox(height: 16),
            // Or support inside a screen of yours.
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  appBar: AppBar(title: const Text("Your app's screen")),
                  body: TicketRackrSupport(
                    getSupportLink: getSupportLink,
                    closable: true,
                    onReady: () => _note('ready'),
                    onUnreadChange: (count) => _note('unread $count'),
                    onClose: () => Navigator.of(context).pop(),
                  ),
                ),
              )),
              child: const Text('Support in a screen'),
            ),
            const SizedBox(height: 16),
            Text(_log.reversed.take(5).toList().reversed.join(' | '), style: const TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}
