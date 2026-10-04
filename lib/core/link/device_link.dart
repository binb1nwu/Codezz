/// How a linked ZCode desktop is reached.
enum DeviceLinkKind {
  /// ZCode's cloud remote-control relay, i.e. the link the desktop app shows
  /// under 远程控制: `https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…&mid=…`.
  relay,

  /// A `zcode --web` server reached directly, e.g.
  /// `http://192.168.1.8:3030/?token=AbC…`.
  web,
}

/// A link to one ZCode desktop.
///
/// Relay links authenticate with an HMAC proof derived from `hash` (see
/// `relay_socket.dart`); web links carry the server token that
/// `packages/server/src/http.ts` checks on `/api/*` and `/ws`.
class DeviceLink {
  const DeviceLink._web(this.base, this.token)
      : kind = DeviceLinkKind.web,
        sid = null,
        passHash = null,
        issuedAt = null,
        machineId = null,
        desktopName = null,
        desktopVersion = null,
        _source = null;

  const DeviceLink._relay({
    required this.base,
    required String this.sid,
    required String this.passHash,
    required int this.issuedAt,
    required Uri source,
    this.machineId,
    this.desktopName,
    this.desktopVersion,
  })  : kind = DeviceLinkKind.relay,
        token = null,
        _source = source;

  final DeviceLinkKind kind;

  /// Web: origin plus the directory the Web UI is served from, always ending
  /// in `/`. Relay: the relay origin.
  final Uri base;

  /// Web only: the `zcode --web` access token.
  final String? token;

  /// Relay only: the desktop's remote session id (`sid`).
  final String? sid;

  /// Relay only: the pairing secret (`hash`) used to sign the auth challenge.
  final String? passHash;

  /// Relay only: when the desktop issued the link (`t`, epoch ms).
  final int? issuedAt;

  /// Relay only: the desktop machine id (`mid`), routes the relay socket.
  final String? machineId;

  /// Relay only: the desktop's display name (`name`).
  final String? desktopName;

  /// Relay only: the desktop app version (`app_version`).
  final String? desktopVersion;

  final Uri? _source;

  bool get isRelay => kind == DeviceLinkKind.relay;

  static DeviceLink? tryParse(String raw) => parse(raw).link;

  static DeviceLinkParseResult parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const DeviceLinkParseResult.error('empty');
    // Links copied from terminals sometimes carry a trailing punctuation.
    text = text.replaceAll(RegExp(r'[\s"<>]+$'), '');
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
      text = 'http://$text';
    }
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return const DeviceLinkParseResult.error('invalid');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return const DeviceLinkParseResult.error('invalid');
    }
    if (uri.host.isEmpty) return const DeviceLinkParseResult.error('invalid');
    final q = uri.queryParameters;
    if (q.containsKey('sid') || q.containsKey('hash')) return _parseRelay(uri);

    final token = q['token']?.trim();
    var path = uri.path;
    if (path.isEmpty || !path.endsWith('/')) {
      final slash = path.lastIndexOf('/');
      path = slash < 0 ? '/' : path.substring(0, slash + 1);
    }
    final base = Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
    return DeviceLinkParseResult.ok(
        DeviceLink._web(base, token == null || token.isEmpty ? null : token));
  }

  /// Mirrors `zC()` in ZCode's remote web client: `sid`, `hash` and `t` are
  /// required, the rest is informational.
  static DeviceLinkParseResult _parseRelay(Uri uri) {
    String? get(String key) {
      final v = uri.queryParameters[key]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    final sid = get('sid');
    final hash = get('hash');
    final t = int.tryParse(get('t') ?? '');
    if (sid == null || hash == null || t == null) {
      return const DeviceLinkParseResult.error('relayIncomplete');
    }
    final base = Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
    return DeviceLinkParseResult.ok(DeviceLink._relay(
      base: base,
      sid: sid,
      passHash: hash,
      issuedAt: t,
      source: uri,
      machineId: get('mid'),
      desktopName: get('name'),
      desktopVersion: get('app_version'),
    ));
  }

  Map<String, String> get _auth => token == null ? const {} : {'token': token!};

  /// Web only.
  Uri get serverInfoUri =>
      base.resolve('api/server-info').replace(queryParameters: _auth.isEmpty ? null : _auth);

  /// Web: the RPC socket. Relay: the relay socket
  /// (`wss://<host>/ws?mid=…`, as `Jc()` in the remote web client).
  Uri get webSocketUri {
    final secure = base.scheme == 'https';
    if (isRelay) {
      return Uri(
        scheme: secure ? 'wss' : 'ws',
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: '/ws',
        queryParameters: machineId == null ? null : {'mid': machineId!},
      );
    }
    final ws = base.resolve('ws');
    return ws.replace(
      scheme: secure ? 'wss' : 'ws',
      queryParameters: _auth.isEmpty ? null : _auth,
    );
  }

  /// The link in canonical form (what gets stored).
  String get canonical {
    if (isRelay) return _source.toString();
    return (token == null ? base : base.replace(queryParameters: _auth)).toString();
  }

  /// Identifies the desktop behind the link, so pasting a fresh link for an
  /// already linked computer updates it instead of adding a duplicate.
  String get identity => isRelay
      ? 'relay:${base.host}:${machineId ?? sid}'
      : 'web:${base.toString()}';

  /// Short, secret-free description for display and logs, e.g.
  /// `192.168.1.8:3030` or `Bin · zcode.z.ai`.
  String get displayHost {
    if (isRelay) {
      return desktopName == null ? base.host : '$desktopName · ${base.host}';
    }
    return base.hasPort ? '${base.host}:${base.port}' : base.host;
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceLink && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;
}

class DeviceLinkParseResult {
  const DeviceLinkParseResult.ok(DeviceLink this.link) : error = null;
  const DeviceLinkParseResult.error(String this.error) : link = null;

  final DeviceLink? link;

  /// `empty`, `invalid` or `relayIncomplete`.
  final String? error;
}
