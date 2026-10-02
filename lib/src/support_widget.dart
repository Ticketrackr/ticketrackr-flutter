import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'protocol.dart';

const _files = MethodChannel('ticketrackr_support/files');

/// iOS needs no native code: files open in the in-app browser view.
class TicketRackrSupportIOS {
  static void registerWith() {}
}

/// Gets a new one-time support link from your server: the `url` from POST /v1/support-portal/links, made for the
/// signed-in customer. Called when support opens and again whenever its session ends. Your TicketRackr key stays on
/// your server.
typedef GetSupportLink = Future<String> Function();

/// The company's support inside your app: requests and reports with their forms, the conversation, files, the AI
/// assistant and surveys. It fills the space it's given. Files and TicketRackr pages (the status page, help articles)
/// open in the in-app browser view; other sites, mail and phone links in their own apps.
class TicketRackrSupport extends StatefulWidget {
  const TicketRackrSupport({
    super.key,
    required this.getSupportLink,
    this.options = const SupportOptions(),
    this.closable = false,
    this.onReady,
    this.onUnreadChange,
    this.onClose,
  });

  /// Gets a new support link from your server.
  final GetSupportLink getSupportLink;

  /// What to open: a request type's form, filled in, in a language.
  final SupportOptions options;

  /// Show a Close button, for support on a screen of its own; [onClose] hears it.
  final bool closable;

  /// Support has loaded and signed in.
  final VoidCallback? onReady;

  /// The customer's unread replies, whenever the number changes.
  final ValueChanged<int>? onUnreadChange;

  /// The customer pressed Close.
  final VoidCallback? onClose;

  @override
  State<TicketRackrSupport> createState() => _TicketRackrSupportState();
}

class _TicketRackrSupportState extends State<TicketRackrSupport> {
  late final WebViewController _controller;
  late final SupportWords _words = SupportWords.forLanguage(widget.options.language);
  String? _origin;
  int _loads = 0;
  int _request = 0;
  ReconnectGuard _reconnect = ReconnectGuard();
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(allowsInlineMediaPlayback: true, mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{})
        : const PlatformWebViewControllerCreationParams();
    _controller = WebViewController.fromPlatformCreationParams(params);
    unawaited(_controller.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(_controller.setBackgroundColor(Colors.white));
    // The page tells the app what happened through window.TicketRackrSupportBridge (sdks/protocol, section 3).
    unawaited(_controller.addJavaScriptChannel('TicketRackrSupportBridge', onMessageReceived: (message) => _received(message.message)));
    unawaited(_controller.addJavaScriptChannel('TicketRackrSupportFiles', onMessageReceived: (message) => unawaited(_openFile(message.message))));
    unawaited(_controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: _decide,
      onPageFinished: (_) => _show(loading: false),
      onWebResourceError: (error) {
        if (error.isForMainFrame ?? false) _fail(error.description);
      },
    )));
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setMediaPlaybackRequiresUserGesture(false));
      unawaited(platform.setOnShowFileSelector(_chooseFiles));
    }
    unawaited(_open());
  }

  /// Gets a new link and shows it.
  Future<void> _open() async {
    final ticket = ++_request;
    _show(loading: true);
    try {
      final link = await widget.getSupportLink();
      if (!mounted || ticket != _request) return;
      // iOS tells the page its own screen edges; Android tells it the window's, so the page needn't use them there.
      final url = SupportAddress.frameUrl(link, options: widget.options, closable: widget.closable, edges: defaultTargetPlatform == TargetPlatform.iOS, load: ++_loads);
      _origin = SupportOrigin.of(url.toString());
      await _controller.loadRequest(url);
    } catch (error) {
      if (mounted && ticket == _request) _fail('$error');
    }
  }

  void _show({bool loading = false, bool failed = false}) {
    if (!mounted || (_loading == loading && _failed == failed)) return;
    setState(() {
      _loading = loading;
      _failed = failed;
    });
  }

  void _fail(String reason) {
    debugPrint('TicketRackr: support couldn\'t open: $reason');
    _show(failed: true);
  }

  Future<void> _received(String data) async {
    // Only the support page this view shows.
    final origin = _origin;
    if (origin == null || !SupportOrigin.isSupport(await _controller.currentUrl(), origin) || !mounted) return;
    switch (SupportEvent.read(data)) {
      case SupportReady():
        _show(loading: false);
        widget.onReady?.call();
      case SupportUnread(:final count):
        widget.onUnreadChange?.call(count);
      case SupportClose():
        widget.onClose?.call();
      case SupportSessionEnded():
        if (_reconnect.allow()) {
          unawaited(_open());
        } else {
          _fail('the session keeps ending');
        }
      case null:
        break;
    }
  }

  FutureOr<NavigationDecision> _decide(NavigationRequest request) {
    final origin = _origin;
    // Frames inside the page load as they are.
    if (!request.isMainFrame || origin == null || request.url == 'about:blank') return NavigationDecision.navigate;
    switch (SupportDestination.of(request.url, origin)) {
      case SupportDestination.support:
        return NavigationDecision.navigate;
      case SupportDestination.file:
        unawaited(_fetchFile(request.url));
      case SupportDestination.page:
        unawaited(launchUrl(Uri.parse(request.url), mode: LaunchMode.inAppBrowserView));
      case SupportDestination.outside:
        unawaited(launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication));
    }
    return NavigationDecision.prevent;
  }

  // A file opened with the page's sign-in is sent on to a link that works without it for two minutes
  // (sdks/protocol, section 4): the page asks for it, and the in-app browser view opens that link.
  Future<void> _fetchFile(String url) => _controller.runJavaScript('''
(async () => {
  try {
    const response = await fetch(${jsonEncode(url)}, { credentials: "include" });
    const headers = response.headers;
    TicketRackrSupportFiles.postMessage(JSON.stringify(response.ok
      ? { url: response.url, disposition: headers.get("content-disposition"), type: headers.get("content-type") }
      : {}));
    if (response.body) response.body.cancel();
  } catch (error) {
    TicketRackrSupportFiles.postMessage("{}");
  }
})();''');

  /// Android: the system's downloads, and support stays. iOS: the in-app browser view shows the file.
  Future<void> _openFile(String message) async {
    final origin = _origin;
    final file = jsonDecode(message);
    if (origin == null || file is! Map || file['url'] is! String) return;
    final link = file['url'] as String;
    if (SupportDestination.of(link, origin) != SupportDestination.file) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _files.invokeMethod<bool>('download', {'url': link, 'disposition': file['disposition'], 'type': file['type'], 'downloading': _words.downloading});
        return;
      } on PlatformException catch (error) {
        debugPrint('TicketRackr: the file couldn\'t be downloaded: ${error.message}');
      }
    }
    await launchUrl(Uri.parse(link), mode: LaunchMode.inAppBrowserView);
  }

  /// Android: the system's picker, for files to attach (iOS shows its own).
  Future<List<String>> _chooseFiles(FileSelectorParams params) async {
    final types = params.acceptTypes.where((type) => type.trim().isNotEmpty).map((type) => type.trim()).toList();
    final group = XTypeGroup(
      mimeTypes: types.where((type) => type.contains('/')).toList(),
      extensions: types.where((type) => type.startsWith('.')).map((type) => type.substring(1)).toList(),
    );
    final groups = group.allowsAny ? <XTypeGroup>[] : [group];
    final files = params.mode == FileSelectorMode.openMultiple
        ? await openFiles(acceptedTypeGroups: groups)
        : [if (await openFile(acceptedTypeGroups: groups) case final XFile file) file];
    return files.map((file) => Uri.file(file.path).toString()).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _controller)),
          if (_loading || _failed)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_failed) const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(_failed ? _words.failed : _words.loading, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF334155), fontSize: 15)),
                        if (_failed)
                          TextButton(
                            onPressed: () {
                              _reconnect = ReconnectGuard();
                              unawaited(_open());
                            },
                            child: Text(_words.retry),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens support on a screen of its own, with a Close button (and the back button). Completes when it closes.
Future<void> showTicketRackrSupport(
  BuildContext context, {
  required GetSupportLink getSupportLink,
  SupportOptions options = const SupportOptions(),
  ValueChanged<int>? onUnreadChange,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (context) => Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: TicketRackrSupport(
          getSupportLink: getSupportLink,
          options: options,
          closable: true,
          onUnreadChange: onUnreadChange,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    ),
  ));
}

/// A Help button that opens support on a screen of its own. Its badge counts the replies left unread when support was
/// last open.
class SupportButton extends StatefulWidget {
  const SupportButton({
    super.key,
    required this.getSupportLink,
    this.options = const SupportOptions(),
    this.label,
    this.color = const Color(0xFF16776B),
    this.onOpenChange,
  });

  /// Gets a new support link from your server.
  final GetSupportLink getSupportLink;

  /// What to open: a request type's form, filled in, in a language.
  final SupportOptions options;

  /// The button's text. "Help", in the support language, when left out.
  final String? label;

  /// The button's color: your brand color.
  final Color color;

  /// Support opened or closed.
  final ValueChanged<bool>? onOpenChange;

  @override
  State<SupportButton> createState() => _SupportButtonState();
}

class _SupportButtonState extends State<SupportButton> {
  int _unread = 0;

  Future<void> _open() async {
    widget.onOpenChange?.call(true);
    await showTicketRackrSupport(
      context,
      getSupportLink: widget.getSupportLink,
      options: widget.options,
      onUnreadChange: (count) {
        if (mounted) setState(() => _unread = count);
      },
    );
    widget.onOpenChange?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final words = SupportWords.forLanguage(widget.options.language);
    final name = widget.label ?? words.help;
    return Semantics(
      button: true,
      label: _unread > 0 ? '$name, $_unread ${words.unread}' : name,
      excludeSemantics: true,
      child: FilledButton(
        onPressed: _open,
        style: FilledButton.styleFrom(
          backgroundColor: widget.color,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            if (_unread > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(999))),
                child: Text('$_unread', style: TextStyle(color: widget.color, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
