import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'document_preview.dart';

import '../../core/zcode/zcode_api.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/markdown_view.dart';

/// How ZCode's code viewer shows a file, by extension.
enum PreviewKind { image, video, audio, pdf, pptx, docx, sheet, legacyOffice, markdown, text }

PreviewKind previewKind(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
  final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : '';
  return switch (ext) {
    'apng' || 'avif' || 'bmp' || 'gif' || 'ico' || 'jpeg' || 'jpg' || 'png' || 'webp' => PreviewKind.image,
    'mp4' || 'mov' || 'webm' || 'm4v' => PreviewKind.video,
    'mp3' || 'wav' || 'm4a' || 'ogg' || 'opus' || 'flac' || 'weba' => PreviewKind.audio,
    'pdf' => PreviewKind.pdf,
    'pptx' => PreviewKind.pptx,
    'docx' => PreviewKind.docx,
    'xlsx' || 'xlsm' || 'xls' => PreviewKind.sheet,
    'doc' || 'ppt' => PreviewKind.legacyOffice,
    'md' || 'markdown' => PreviewKind.markdown,
    _ => PreviewKind.text,
  };
}

IconData previewIcon(String path) => switch (previewKind(path)) {
      PreviewKind.image => Icons.image_outlined,
      PreviewKind.video => Icons.movie_outlined,
      PreviewKind.audio => Icons.audiotrack_outlined,
      PreviewKind.pdf => Icons.picture_as_pdf_outlined,
      PreviewKind.pptx => Icons.slideshow_outlined,
      PreviewKind.sheet => Icons.table_chart_outlined,
      PreviewKind.docx || PreviewKind.legacyOffice => Icons.article_outlined,
      PreviewKind.markdown || PreviewKind.text => Icons.description_outlined,
    };

bool _windowsPath(String p) => RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) || p.startsWith(r'\\');

/// First path segments that make `/x/…` an absolute path rather than one
/// relative to the workspace (as ZCode's link resolver decides).
const _systemRoots = {
  'Users', 'home', 'tmp', 'usr', 'var', 'opt', 'etc', 'mnt', 'root', 'private', 'Volumes', 'srv', 'data',
};

/// The desktop path a Markdown link points at, or null for web links and
/// paths that leave the workspace. Relative links resolve against [root];
/// `file://` URLs, `:line[:col]` and `#L12` suffixes are understood.
String? resolveLocalPath(String root, String href) {
  var h = href.trim();
  if (h.isEmpty || h.startsWith('#')) return null;
  if (h.startsWith('file://')) {
    h = h.substring(7);
    if (RegExp(r'^/[A-Za-z]:').hasMatch(h)) h = h.substring(1);
  } else if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(h) && !_windowsPath(h)) {
    return null; // http:, mailto:, …
  }
  try {
    h = Uri.decodeFull(h);
  } on ArgumentError {
    // Keep it as written.
  }
  h = h.replaceFirst(RegExp(r'#L\d+.*$'), '').replaceFirst(RegExp(r':\d+(:\d+)?$'), '');
  if (h.isEmpty || h.startsWith('~')) return null;
  final win = _windowsPath(root);
  final sep = win ? r'\' : '/';
  final rootNorm = root.endsWith('/') || root.endsWith(r'\') ? root.substring(0, root.length - 1) : root;
  if (_windowsPath(h)) return h;
  if (h.startsWith('/')) {
    final first = h.split('/').where((s) => s.isNotEmpty).firstOrNull ?? '';
    if (!win && (h.startsWith('$rootNorm/') || h == rootNorm || _systemRoots.contains(first))) return h;
    h = h.substring(1);
  }
  final parts = rootNorm.split(RegExp(r'[\\/]'));
  final rootDepth = parts.length;
  for (final seg in h.split(RegExp(r'[\\/]'))) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.length <= rootDepth) return null; // outside the workspace
      parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join(sep);
}

/// Lets rows and Markdown links open desktop files in the side pane.
class FileLinkScope extends InheritedWidget {
  const FileLinkScope({super.key, required this.root, required this.onOpen, required super.child});

  /// The workspace root relative links resolve against.
  final String root;
  final ValueChanged<String> onOpen;

  static FileLinkScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<FileLinkScope>();

  /// Opens [href] if it is a local path; false for web links.
  bool openLink(String href) {
    final path = resolveLocalPath(root, href);
    if (path == null) return false;
    onOpen(path);
    return true;
  }

  @override
  bool updateShouldNotify(FileLinkScope old) => old.root != root || old.onOpen != onOpen;
}

/// ZCode's code viewer for one file: a header (name, folder, ⋯ menu) over
/// the renderer for its kind.
class FilePreview extends StatefulWidget {
  const FilePreview({super.key, required this.api, required this.path, required this.root});
  final ZCodeApi? api;
  final String path;

  /// Workspace root, for the relative path.
  final String root;

  @override
  State<FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<FilePreview> {
  bool _wrap = false;
  bool _markdownSource = false;

  String get _name => widget.path.split(RegExp(r'[\\/]')).last;

  String get _relative {
    final root = widget.root;
    final p = widget.path;
    if (root.isNotEmpty && p.startsWith(root)) {
      final rest = p.substring(root.length);
      return rest.replaceFirst(RegExp(r'^[\\/]'), '');
    }
    return p;
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final kind = previewKind(widget.path);
    final textual = kind == PreviewKind.text || (kind == PreviewKind.markdown && _markdownSource);
    final dir = _relative.contains(RegExp(r'[\\/]'))
        ? _relative.substring(0, _relative.lastIndexOf(RegExp(r'[\\/]')))
        : '';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 44,
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          color: z.surface,
          border: Border(bottom: BorderSide(color: z.border)),
        ),
        child: Row(children: [
          Icon(previewIcon(widget.path), size: 16, color: z.foregroundSubtle),
          const SizedBox(width: 8),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foreground)),
              if (dir.isNotEmpty)
                Text(dir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtlest)),
            ]),
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: s.more,
            icon: Icon(Icons.more_horiz, size: 18, color: z.foregroundSubtle),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              if (kind == PreviewKind.markdown)
                CheckedPopupMenuItem(
                  value: () => setState(() => _markdownSource = !_markdownSource),
                  checked: _markdownSource,
                  child: Text(s.markdownSource),
                ),
              if (textual)
                CheckedPopupMenuItem(
                  value: () => setState(() => _wrap = !_wrap),
                  checked: _wrap,
                  child: Text(s.wrapLines),
                ),
              PopupMenuItem(
                value: () => _copy(widget.path),
                child: Text(s.copyAbsolutePath),
              ),
              if (_relative != widget.path)
                PopupMenuItem(
                  value: () => _copy(_relative),
                  child: Text(s.copyRelativePath),
                ),
            ],
          ),
        ]),
      ),
      Expanded(child: _body(kind, s)),
    ]);
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    showToast(context, S.of(context).copied);
  }

  Widget _body(PreviewKind kind, S s) {
    final api = widget.api;
    if (api == null) return PreviewMessage(s.offlineBanner);
    return switch (kind) {
      PreviewKind.image => _ImagePreview(api: api, path: widget.path),
      PreviewKind.video || PreviewKind.audio =>
        _MediaPreview(api: api, path: widget.path, audio: kind == PreviewKind.audio),
      PreviewKind.pdf || PreviewKind.pptx || PreviewKind.docx || PreviewKind.sheet =>
        DocumentPreview(api: api, path: widget.path, kind: kind),
      PreviewKind.legacyOffice => PreviewMessage(s.officeUnavailable),
      PreviewKind.markdown => _TextPreview(api: api, path: widget.path, wrap: _wrap, markdown: !_markdownSource),
      PreviewKind.text => _TextPreview(api: api, path: widget.path, wrap: _wrap),
    };
  }
}

/// A centred status line (`p-3 text-ui-base`).
class PreviewMessage extends StatelessWidget {
  const PreviewMessage(this.text, {super.key, this.error = false, this.loading = false});
  final String text;
  final bool error;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (loading) ...[const ZSpinner(size: 16), const SizedBox(height: 12)],
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: ZText.base, color: error ? z.destructive : z.foregroundSubtle)),
        ]),
      ),
    );
  }
}

/// ENOENT and friends read as "missing", anything else as its message.
String previewError(Object error, S s) {
  final text = '$error';
  if (RegExp(r'ENOENT|no such file or directory', caseSensitive: false).hasMatch(text)) return s.fileMissing;
  return text;
}

class _TextPreview extends StatefulWidget {
  const _TextPreview({required this.api, required this.path, required this.wrap, this.markdown = false});
  final ZCodeApi api;
  final String path;
  final bool wrap;
  final bool markdown;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  late final Future<Map<String, dynamic>> _read = widget.api.readTextFile(widget.path);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return FutureBuilder(
      future: _read,
      builder: (context, snap) {
        if (snap.hasError) return PreviewMessage(previewError(snap.error!, s), error: true);
        final res = snap.data;
        if (res == null) return PreviewMessage(s.loadingFile, loading: true);
        if (res['isBinary'] == true) return PreviewMessage(s.binaryFile);
        if (res['truncated'] == true) return PreviewMessage(s.fileTooLarge);
        final content = res['content'] as String? ?? '';
        if (content.isEmpty) return PreviewMessage(s.emptyFile);
        if (widget.markdown) {
          return SingleChildScrollView(padding: const EdgeInsets.all(16), child: MarkdownView(frontMatterAsCode(content)));
        }
        return CodeLines(text: content, wrap: widget.wrap);
      },
    );
  }
}

/// A file's text with a line-number gutter; lines scroll sideways unless
/// [wrap].
class CodeLines extends StatelessWidget {
  const CodeLines({super.key, required this.text, this.wrap = false});
  final String text;
  final bool wrap;

  static const _fontSize = 12.0;
  static const _height = 1.6;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final lines = text.endsWith('\n') ? text.substring(0, text.length - 1).split('\n') : text.split('\n');
    final style = TextStyle(
      fontFamily: zMonoFamily,
      fontFamilyFallback: zMonoFallback,
      fontSize: _fontSize,
      height: _height,
      color: z.foreground,
    );
    final gutterStyle = style.copyWith(color: z.foregroundSubtlest);
    final digits = '${lines.length}'.length;
    final charWidth = (TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout())
        .width;
    final gutter = charWidth * digits + 24;

    Widget line(int i) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: gutter,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('${i + 1}', textAlign: TextAlign.right, style: gutterStyle),
            ),
          ),
          if (wrap)
            Expanded(child: Text(lines[i], style: style))
          else
            Text(lines[i].replaceAll('\t', '    '), softWrap: false, style: style),
        ]);

    final list = ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: lines.length,
      itemBuilder: (context, i) => line(i),
    );
    if (wrap) return SelectionArea(child: list);
    final longest = lines.fold<int>(0, (m, l) => math.max(m, l.replaceAll('\t', '    ').length));
    return LayoutBuilder(
      builder: (context, c) => SelectionArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(c.maxWidth, gutter + longest * charWidth + 24),
            height: c.maxHeight,
            child: list,
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.api, required this.path});
  final ZCodeApi api;
  final String path;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  late final Future<Map<String, dynamic>> _read = widget.api.readMediaPreview(widget.path);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return FutureBuilder(
      future: _read,
      builder: (context, snap) {
        if (snap.hasError) return PreviewMessage(previewError(snap.error!, s), error: true);
        final res = snap.data;
        if (res == null) return PreviewMessage(s.loadingImage, loading: true);
        final data = res['dataBase64'] as String?;
        if (data == null || data.isEmpty) return PreviewMessage(s.imageUnavailable);
        final bytes = base64Decode(data);
        // Checkerboard behind transparent images; pinch to zoom.
        return CustomPaint(
          painter: _Checkerboard(context.z.border),
          child: InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.scaleDown,
                  errorBuilder: (context, _, __) => PreviewMessage(s.imageUnavailable),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Checkerboard extends CustomPainter {
  _Checkerboard(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 8.0;
    final paint = Paint()..color = color;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = ((y / cell).floor().isOdd ? cell : 0.0); x < size.width; x += cell * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => old.color != color;
}

/// Video / audio: the file is copied from the desktop in 1 MB ranges into
/// the app's cache (the desktop's own preview URL is local to it), then
/// played there.
class _MediaPreview extends StatefulWidget {
  const _MediaPreview({required this.api, required this.path, required this.audio});
  final ZCodeApi api;
  final String path;
  final bool audio;

  /// Larger files are not copied over.
  static const maxBytes = 300 * 1024 * 1024;
  static const chunk = 1024 * 1024;

  @override
  State<_MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<_MediaPreview> {
  VideoPlayerController? _player;
  int _received = 0;
  int? _total;
  String? _error;
  bool _tooLarge = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<File> _cacheFile() async {
    final dir = Directory('${Directory.systemTemp.path}/codezz_preview');
    await dir.create(recursive: true);
    final ext = widget.path.contains('.') ? widget.path.substring(widget.path.lastIndexOf('.')) : '';
    final name = sha1.convert(utf8.encode(widget.path)).toString();
    return File('${dir.path}/$name$ext');
  }

  Future<void> _load() async {
    try {
      final stat = await widget.api.statFile(widget.path);
      final size = (stat['size'] as num?)?.toInt();
      if (size != null && size > _MediaPreview.maxBytes) {
        setState(() => _tooLarge = true);
        return;
      }
      setState(() => _total = size);
      final file = await _cacheFile();
      // A copy of the same size from an earlier visit is reused.
      if (!(size != null && await file.exists() && await file.length() == size)) {
        final sink = file.openWrite();
        try {
          var offset = 0;
          while (!_disposed) {
            final bytes = await widget.api.readFileRange(widget.path, offset, _MediaPreview.chunk);
            if (bytes.isEmpty) break;
            sink.add(bytes);
            offset += bytes.length;
            if (mounted) setState(() => _received = offset);
            if (offset > _MediaPreview.maxBytes) throw StateError('too large');
          }
        } finally {
          await sink.close();
        }
      }
      if (_disposed) return;
      final player = VideoPlayerController.file(file);
      await player.initialize();
      if (_disposed) {
        await player.dispose();
        return;
      }
      player.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _player = player);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final z = context.z;
    if (_tooLarge) return PreviewMessage(s.mediaTooLarge);
    if (_error != null) {
      final missing = previewError(_error!, s);
      return PreviewMessage(missing == s.fileMissing ? missing : s.mediaLoadFailed, error: missing != s.fileMissing);
    }
    final player = _player;
    if (player == null) {
      final total = _total;
      return PreviewMessage(
        total == null || total == 0
            ? s.loadingMedia
            : '${s.loadingMedia} ${(_received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
        loading: true,
      );
    }
    final value = player.value;
    if (value.hasError) return PreviewMessage(s.mediaUnsupported, error: true);
    final controls = _MediaControls(player: player);
    if (widget.audio) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.audiotrack_rounded, size: 48, color: z.foregroundSubtlest),
            const SizedBox(height: 16),
            controls,
          ]),
        ),
      );
    }
    return Column(children: [
      Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: AspectRatio(
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
              child: ClipRRect(borderRadius: BorderRadius.circular(ZRadius.lg), child: VideoPlayer(player)),
            ),
          ),
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: controls),
    ]);
  }
}

class _MediaControls extends StatelessWidget {
  const _MediaControls({required this.player});
  final VideoPlayerController player;

  static String _time(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final value = player.value;
    final total = value.duration.inMilliseconds;
    final mono = TextStyle(
        fontSize: ZText.sm, color: z.foregroundSubtle, fontFeatures: const [FontFeature.tabularFigures()]);
    return Row(children: [
      ZIconButton(
        icon: value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        onPressed: () async {
          if (value.isPlaying) return player.pause();
          // Finished: play again from the start.
          if (value.duration > Duration.zero && value.position >= value.duration) {
            await player.seekTo(Duration.zero);
          }
          await player.play();
        },
      ),
      Text(_time(value.position), style: mono),
      Expanded(
        child: Slider(
          value: total == 0 ? 0 : value.position.inMilliseconds.clamp(0, total).toDouble(),
          max: math.max(total, 1).toDouble(),
          activeColor: z.foreground,
          inactiveColor: z.secondary,
          onChanged: (v) => player.seekTo(Duration(milliseconds: v.round())),
        ),
      ),
      Text(_time(value.duration), style: mono),
    ]);
  }
}

/// YAML front matter (`---` … `---` at the top) as a yaml code block, so it
/// doesn't render as a setext heading.
String frontMatterAsCode(String markdown) {
  final m = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)').firstMatch(markdown);
  if (m == null) return markdown;
  return '```yaml\n${m.group(1)}\n```\n${markdown.substring(m.end)}';
}
