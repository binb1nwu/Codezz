import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/zcode/zcode_api.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import 'file_preview.dart';

/// PDF / PPTX / DOCX / spreadsheets, drawn like ZCode's preview pane: the
/// file is copied from the desktop in 1 MB ranges and handed to a WebView
/// running the same kind of renderers the web client uses (pdf.js,
/// pptx-preview, docx-preview, SheetJS; see `assets/preview/`).
class DocumentPreview extends StatefulWidget {
  const DocumentPreview({super.key, required this.api, required this.path, required this.kind});
  final ZCodeApi api;
  final String path;
  final PreviewKind kind;

  /// ZCode's PPTX limit, used for every kind (the phone holds it in memory).
  static const maxBytes = 64 * 1024 * 1024;
  static const chunk = 1024 * 1024;

  static const _asset = 'assets/preview/viewer.html';

  @override
  State<DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<DocumentPreview> {
  WebViewController? _web;
  final _ready = Completer<void>();
  int _received = 0;
  int? _total;
  String? _error;
  bool _tooLarge = false;
  bool _empty = false;
  bool _rendered = false;
  bool _disposed = false;

  String get _renderer => switch (widget.kind) {
        PreviewKind.pdf => 'pdf',
        PreviewKind.pptx => 'pptx',
        PreviewKind.docx => 'docx',
        _ => 'xlsx',
      };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _fail(Object e) {
    if (mounted) setState(() => _error = '$e');
  }

  Future<void> _load() async {
    try {
      final stat = await widget.api.statFile(widget.path);
      final size = (stat['size'] as num?)?.toInt();
      if (_disposed) return;
      if (size != null && size > DocumentPreview.maxBytes) return setState(() => _tooLarge = true);
      if (size == 0) return setState(() => _empty = true);
      setState(() => _total = size);
      final web = _createWebView();
      setState(() => _web = web);

      final chunks = <Uint8List>[];
      var offset = 0;
      while (!_disposed) {
        final bytes = await widget.api.readFileRange(widget.path, offset, DocumentPreview.chunk);
        if (bytes.isEmpty) break;
        chunks.add(bytes);
        offset += bytes.length;
        if (offset > DocumentPreview.maxBytes) return setState(() => _tooLarge = true);
        if (mounted) setState(() => _received = offset);
      }
      if (_disposed) return;
      if (offset == 0) return setState(() => _empty = true);

      await _ready.future;
      await web.runJavaScript('codezz.begin($offset)');
      for (final c in chunks) {
        if (_disposed) return;
        await web.runJavaScript("codezz.append('${base64Encode(c)}')");
      }
      if (_disposed || !mounted) return;
      await web.runJavaScript('codezz.render(${jsonEncode(_renderer)}, ${jsonEncode(_theme(context.z))})');
    } catch (e) {
      _fail(e);
    }
  }

  /// Opaque CSS colour of [c] over [z.background] (tokens like `border` and
  /// `surface` are translucent; sticky sheet headers must not be).
  static String _css(Color c, ZTokens z) =>
      '#${(Color.alphaBlend(c, z.background).toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Map<String, String> _theme(ZTokens z) => {
        'bg': _css(z.background, z),
        'fg': _css(z.foreground, z),
        'muted': _css(z.foregroundSubtle, z),
        'border': _css(z.border, z),
        'surface': _css(Color.alphaBlend(z.surface, z.secondary), z),
      };

  WebViewController _createWebView() {
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(context.z.background)
      ..enableZoom(true)
      ..setOnConsoleMessage((m) {
        if (kDebugMode) debugPrint('[preview] ${m.level.name}: ${m.message}');
      })
      ..addJavaScriptChannel('Codezz', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        // Only the viewer page itself; links in documents stay put.
        onNavigationRequest: (r) =>
            r.url.endsWith(DocumentPreview._asset) ? NavigationDecision.navigate : NavigationDecision.prevent,
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) _fail(e.description);
        },
      ))
      ..loadFlutterAsset(DocumentPreview._asset);
    return web;
  }

  Future<void> _onMessage(String text) async {
    final Map msg;
    try {
      msg = jsonDecode(text) as Map;
    } on FormatException {
      return;
    }
    switch (msg['type']) {
      case 'ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'done':
        if (mounted) setState(() => _rendered = true);
      case 'error':
        _fail(msg['message'] ?? '');
      case 'cmap':
        final name = '${msg['name']}';
        String? data;
        // CMap names are plain identifiers like UniGB-UCS2-H.
        if (RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
          try {
            final bytes = await rootBundle.load('assets/preview/cmaps/$name.bcmap');
            data = base64Encode(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
          } catch (_) {
            // Unknown CMap: pdf.js reports it.
          }
        }
        await _web?.runJavaScript('codezz.cmap(${jsonEncode(name)}, ${jsonEncode(data)})');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final z = context.z;
    if (_tooLarge) return PreviewMessage(s.documentTooLarge);
    if (_empty) return PreviewMessage(s.emptyFile);
    final error = _error;
    if (error != null) {
      final shown = previewError(error, s);
      if (shown == s.fileMissing) return PreviewMessage(shown);
      final title = switch (widget.kind) {
        PreviewKind.pdf => s.pdfUnavailable,
        PreviewKind.pptx => s.pptxLoadError,
        _ => s.officeUnavailable,
      };
      return PreviewMessage(shown.isEmpty ? title : '$title\n$shown', error: true);
    }
    final total = _total;
    final loading = switch (widget.kind) {
      PreviewKind.pdf => s.loadingPdf,
      PreviewKind.pptx => s.loadingPptx,
      _ => s.loadingFile,
    };
    final web = _web;
    return Stack(fit: StackFit.expand, children: [
      if (web != null)
        WebViewWidget(
          controller: web,
          gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
        ),
      if (!_rendered)
        ColoredBox(
          color: z.background,
          child: PreviewMessage(
            total == null || total == 0 || _received == 0
                ? loading
                : '$loading ${(_received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
            loading: true,
          ),
        ),
    ]);
  }
}
