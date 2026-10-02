// The embedded support protocol (sdks/protocol in TicketRackr's repository): plain Dart, tested against the cases
// every TicketRackr SDK passes.
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

/// What to open in support: one request type's form, filled in, in a language.
class SupportOptions {
  const SupportOptions({this.requestType, this.subject, this.fields = const {}, this.language});

  /// Opens the form for one request type, by its key (Settings → Companies → Case types), such as a report.
  final String? requestType;

  /// Fills in the request's subject.
  final String? subject;

  /// Fills in the request type's customer-visible fields, by key.
  final Map<String, String> fields;

  /// `en`, `es`, `fr`, `de` or `pt`. The device's language when left out.
  final String? language;
}

/// A support link that isn't TicketRackr's support page.
class SupportLinkException implements Exception {
  @override
  String toString() => 'TicketRackr: getSupportLink must return the support link from POST /v1/support-portal/links.';
}

/// The address support is shown at (sdks/protocol, section 2).
class SupportAddress {
  static final _fieldKey = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  /// The support link in embedded mode, with what to open. [closable] adds a Close button; [edges] lets the page keep
  /// clear of the status bar and home indicator itself; [load] makes each new link really load.
  static Uri frameUrl(String link, {SupportOptions options = const SupportOptions(), bool closable = false, bool edges = false, int load = 0}) {
    final uri = _supportLink(link);
    final params = <String, String>{...uri.queryParameters, 'view': 'embed'};
    if (closable) params['closable'] = '1';
    if (edges) params['edges'] = '1';
    if (load > 0) params['load'] = '$load';
    if (options.language?.isNotEmpty == true) params['lang'] = options.language!;
    if (options.requestType?.isNotEmpty == true) params['type'] = options.requestType!;
    if (options.subject?.isNotEmpty == true) params['subject'] = options.subject!;
    for (final key in options.fields.keys.toList()..sort()) {
      if (!_fieldKey.hasMatch(key)) continue;
      final value = options.fields[key]!;
      params['f.$key'] = value.length > 500 ? value.substring(0, 500) : value;
    }
    return uri.replace(queryParameters: params);
  }

  /// Only TicketRackr's support page, over https (http only while developing on this machine), with its code.
  static Uri _supportLink(String link) {
    final Uri uri;
    try {
      uri = Uri.parse(link);
    } on FormatException {
      throw SupportLinkException();
    }
    final local = uri.host == 'localhost' || uri.host == '127.0.0.1';
    final secure = uri.scheme == 'https' || (uri.scheme == 'http' && local);
    if (!uri.hasAuthority || uri.host.isEmpty || !secure || uri.path != '/support' || !uri.fragment.contains('code=')) {
      throw SupportLinkException();
    }
    return uri;
  }
}

/// What the support page tells the app (sdks/protocol, section 3). Events only, never customer data.
sealed class SupportEvent {
  const SupportEvent();

  /// The event in a message from the page (a JSON string), or null for anything else.
  static SupportEvent? read(String data) {
    final Object? value;
    try {
      value = jsonDecode(data);
    } on FormatException {
      return null;
    }
    if (value is! Map || value['source'] != 'ticketrackr-support') return null;
    switch (value['event']) {
      case 'ready':
        return const SupportReady();
      case 'close':
        return const SupportClose();
      case 'session-ended':
        return const SupportSessionEnded();
      case 'unread':
        final count = value['count'];
        // A whole number of zero or more; not text, a fraction or true/false.
        if (count is int && count >= 0) return SupportUnread(count);
        if (count is double && count >= 0 && count == count.roundToDouble()) return SupportUnread(count.toInt());
        return null;
      default:
        return null;
    }
  }
}

/// Support has loaded and signed in.
class SupportReady extends SupportEvent {
  const SupportReady();
  @override
  bool operator ==(Object other) => other is SupportReady;
  @override
  int get hashCode => 1;
}

/// The customer pressed Close.
class SupportClose extends SupportEvent {
  const SupportClose();
  @override
  bool operator ==(Object other) => other is SupportClose;
  @override
  int get hashCode => 2;
}

/// The session expired or was revoked: support needs a new link.
class SupportSessionEnded extends SupportEvent {
  const SupportSessionEnded();
  @override
  bool operator ==(Object other) => other is SupportSessionEnded;
  @override
  int get hashCode => 3;
}

/// The customer's unread replies, whenever the number changes.
class SupportUnread extends SupportEvent {
  const SupportUnread(this.count);
  final int count;
  @override
  bool operator ==(Object other) => other is SupportUnread && other.count == count;
  @override
  int get hashCode => count.hashCode;
}

/// Origins: scheme, host and port, as browsers compare them.
class SupportOrigin {
  /// An address's origin, like `https://ticketrackr.com`, or null for one without a host (`about:blank`, `mailto:`).
  static String? of(String? url) {
    if (url == null) return null;
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      return null;
    }
    if (!uri.hasScheme || !uri.hasAuthority || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final standard = !uri.hasPort || (scheme == 'https' && uri.port == 443) || (scheme == 'http' && uri.port == 80);
    return standard ? '$scheme://$host' : '$scheme://$host:${uri.port}';
  }

  /// Whether a message came from the support page. Web views give the page's address or only its origin.
  static bool isSupport(String? url, String origin) => of(url) == origin;
}

/// Where a link followed inside support goes (sdks/protocol, section 4).
enum SupportDestination {
  /// The support page itself: it stays in support.
  support,

  /// One of support's files (an attachment).
  file,

  /// Another TicketRackr page, like the status page or a help article.
  page,

  /// Another site, or a mail or phone link.
  outside;

  static final _filePath = RegExp(r'^/api/support/tickets/[A-Za-z0-9_-]+/attachments/[A-Za-z0-9_-]+/download$');

  static SupportDestination of(String url, String origin) {
    if (SupportOrigin.of(url) != origin) return outside;
    final path = Uri.parse(url).path;
    if (path == '/support') return support;
    return _filePath.hasMatch(path) ? file : page;
  }
}

/// When the session keeps ending (twice in 30 seconds), support stops getting new links and offers Try again.
class ReconnectGuard {
  ReconnectGuard({this.windowMs = 30000, this.limit = 2});

  final int windowMs;
  final int limit;
  final _recent = <int>[];

  /// Whether to get a new link now.
  bool allow([int? nowMs]) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    while (_recent.isNotEmpty && now - _recent.first > windowMs) {
      _recent.removeAt(0);
    }
    if (_recent.length >= limit) return false;
    _recent.add(now);
    return true;
  }
}

/// The SDK's own few words, in the support page's languages (sdks/protocol, section 6).
class SupportWords {
  const SupportWords(this.loading, this.failed, this.retry, this.help, this.back, this.unread, this.downloading);

  final String loading;
  final String failed;
  final String retry;
  final String help;
  final String back;
  final String unread;
  final String downloading;

  static const _all = {
    'en': SupportWords('Loading support…', "Support couldn't open.", 'Try again', 'Help', 'Back', 'unread', 'Downloading…'),
    'es': SupportWords('Cargando soporte…', 'No se pudo abrir el soporte.', 'Reintentar', 'Ayuda', 'Volver', 'sin leer', 'Descargando…'),
    'fr': SupportWords('Chargement du support…', "Le support n'a pas pu s'ouvrir.", 'Réessayer', 'Aide', 'Retour', 'non lus', 'Téléchargement…'),
    'de': SupportWords('Support wird geladen…', 'Der Support konnte nicht geöffnet werden.', 'Erneut versuchen', 'Hilfe', 'Zurück', 'ungelesen', 'Wird heruntergeladen…'),
    'pt': SupportWords('Carregando o suporte…', 'Não foi possível abrir o suporte.', 'Tentar de novo', 'Ajuda', 'Voltar', 'não lidas', 'Baixando…'),
  };

  /// The words for [language] (`es`, `pt-BR`…), or the device's language when none is given; English otherwise.
  static SupportWords forLanguage(String? language) {
    final preferred = language ?? PlatformDispatcher.instance.locale.languageCode;
    final code = preferred.toLowerCase().split(RegExp('[-_]')).first;
    return _all[code] ?? _all['en']!;
  }
}
