import 'package:flutter/material.dart';

import '../l10n.dart';
import '../side_pane/file_preview.dart';
import '../theme/tokens.dart';

/// A file a reply points at, shown as a card under it (ZCode's
/// `assistant_preview_card`).
class FileReference {
  const FileReference(this.path, this.kind);

  /// Absolute desktop path.
  final String path;
  final PreviewKind kind;

  String get name => path.split(RegExp(r'[\\/]')).last;
}

// The patterns ZCode's web client scans replies with.
const _exts = r'md|html?|docx|xlsx|pptx|pdf|mp4|mov|webm|m4v|mp3|wav|m4a|ogg|opus|flac|weba';
final _citation = RegExp(r':{1,3}zcode-file-citation\{([^}]*)\}', caseSensitive: false);
final _citationLine = RegExp(r'^[ \t]*:{1,3}zcode-file-citation\{[^}]*\}[ \t]*\r?\n?', multiLine: true, caseSensitive: false);
final _mdLink = RegExp(r'\[([^\]\n]*)\]\(([^)\n]+)\)');
final _fileUrl = RegExp(r'\bfile://[^\s<>()\]`"' "'" r'*，。！？；：、]+', caseSensitive: false, unicode: true);
final _quoted = RegExp('([`"\'])([^`"\'\\r\\n]+?\\.(?:$_exts)(?::\\d+(?::\\d+)?)?)\\1', caseSensitive: false, unicode: true);
final _bare = RegExp(
  r'(?:^|[\s("' "'" r'`,.;:!?，。！？；：、])'
  r'((?:(?:\.{1,2}[\\/]|[a-zA-Z]:[\\/]|\/|[\p{L}\p{N}\p{M}\p{S}_.@()-]+[\\/])[\p{L}\p{N}\p{M}\p{S}_.@() -]+?(?:[\\/][\p{L}\p{N}\p{M}\p{S}_.@() -]+?)*|[\p{L}\p{N}\p{M}\p{S}_.@()-]+)'
  '\\.(?:$_exts)(?::\\d+(?::\\d+)?)?)'
  r'(?=$|[\s)"' "'" r'`,.;:!?，。！？；：、])',
  caseSensitive: false,
  unicode: true,
);

/// The reply without citation directives (they become cards instead).
String stripFileCitations(String text) =>
    text.contains('zcode-file-citation') ? text.replaceAll(_citationLine, '').replaceAll(_citation, '') : text;

String _clean(String s) =>
    s.trim().replaceFirst(RegExp(r'[.,;!?，。！？；：、]+$'), '').replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');

bool _absolute(String p) => p.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(p) || p.startsWith(r'\\');

/// `/`-separated, `.` and `..` resolved.
String _normalize(String p) {
  final s = p.replaceAll(r'\', '/').replaceAll(RegExp(r'/{2,}'), '/');
  final out = <String>[];
  for (final seg in s.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return '${s.startsWith('/') ? '/' : ''}${out.join('/')}';
}

String? _fromFileUrl(String url) {
  final Uri u;
  try {
    u = Uri.parse(url);
  } on FormatException {
    return null;
  }
  if (u.scheme != 'file') return null;
  var p = u.path;
  try {
    p = Uri.decodeFull(p);
  } on ArgumentError {
    // Keep it encoded.
  }
  if (RegExp(r'^/[a-zA-Z]:/').hasMatch(p)) return p.substring(1);
  return u.host.isNotEmpty && u.host != 'localhost' ? '//${u.host}$p' : p;
}

/// [raw] as an absolute path, relative ones against [root]; null for `~`
/// paths and relative ones that climb out of the workspace.
String? _resolve(String root, String raw) {
  final c = _clean(raw);
  if (c.isEmpty || RegExp(r'^~[\\/]').hasMatch(c)) return null;
  final p = RegExp(r'^file://', caseSensitive: false).hasMatch(c) ? _fromFileUrl(c) : c;
  if (p == null) return null;
  if (_absolute(p)) return _normalize(p);
  final rel = <String>[];
  for (final seg in p.replaceAll(r'\', '/').split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (rel.isEmpty) return null;
      rel.removeLast();
      continue;
    }
    rel.add(seg);
  }
  return '${_normalize(root).replaceFirst(RegExp(r'/$'), '')}/${rel.join('/')}';
}

String? _ext(String path) {
  final m = RegExp(r'\.([a-z0-9]+)$').firstMatch(_clean(path).toLowerCase());
  return m?.group(1);
}

/// The kind of card for [path]; Markdown / HTML only get one in ZCode when
/// the turn changed them, so never here.
PreviewKind? _cardKind(String path) => switch (_ext(path)) {
      'pdf' => PreviewKind.pdf,
      'pptx' => PreviewKind.pptx,
      'docx' => PreviewKind.docx,
      'xlsx' => PreviewKind.sheet,
      'mp4' || 'mov' || 'webm' || 'm4v' => PreviewKind.video,
      'mp3' || 'wav' || 'm4a' || 'ogg' || 'opus' || 'flac' || 'weba' => PreviewKind.audio,
      _ => null,
    };

String? _param(String attrs, String name) =>
    RegExp('$name\\s*=\\s*["\']([^"\']+)["\']', caseSensitive: false).firstMatch(attrs)?.group(1)?.trim();

/// The files a reply refers to, in order, as ZCode's web client finds them:
/// citation directives, Markdown links, `file://` URLs, quoted paths and bare
/// paths with a previewable extension, inside the workspace [root]. At most
/// 15, each path once.
List<FileReference> fileReferences(String text, String root) {
  if (text.trim().isEmpty || root.isEmpty) return const [];
  final found = <(int, FileReference)>[];
  final taken = <(int, int)>[];
  bool overlaps(int s, int e) => taken.any((r) => s < r.$2 && e > r.$1);
  void add(String raw, int at) {
    final path = _resolve(root, raw);
    final kind = path == null ? null : _cardKind(path);
    if (path != null && kind != null) found.add((at, FileReference(path, kind)));
  }

  for (final m in _citation.allMatches(text)) {
    taken.add((m.start, m.end));
    final attrs = m.group(1) ?? '';
    final raw = _param(attrs, 'path');
    if (raw == null) continue;
    final path = _resolve(root, raw);
    final kind = path == null ? null : _cardKind(path);
    final declared = switch (_param(attrs, 'artifact_kind')?.toLowerCase()) {
      'document' => PreviewKind.docx,
      'presentation' => PreviewKind.pptx,
      'workbook' => PreviewKind.sheet,
      _ => null,
    };
    if (path != null && kind != null && (declared == null || declared == kind)) {
      found.add((m.start, FileReference(path, kind)));
    }
  }
  for (final m in _mdLink.allMatches(text)) {
    if (overlaps(m.start, m.end)) continue;
    taken.add((m.start, m.end));
    add((m.group(2) ?? '').trim().replaceAll(RegExp(r'^<|>$'), ''), m.start);
  }
  for (final m in _fileUrl.allMatches(text)) {
    if (overlaps(m.start, m.end)) continue;
    taken.add((m.start, m.end));
    add(m.group(0)!, m.start);
  }
  for (final m in _quoted.allMatches(text)) {
    final raw = (m.group(2) ?? '').trim();
    if (raw.isEmpty || overlaps(m.start, m.end)) continue;
    taken.add((m.start, m.end));
    add(raw, m.start);
  }
  for (final m in _bare.allMatches(text)) {
    final raw = m.group(1) ?? '';
    final start = m.start + m.group(0)!.lastIndexOf(raw);
    if (raw.isEmpty || overlaps(start, start + raw.length)) continue;
    add(raw, start);
  }

  found.sort((a, b) => a.$1.compareTo(b.$1));
  final rootNorm = _normalize(root).replaceFirst(RegExp(r'/$'), '');
  final win = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(root) || root.startsWith(r'\\');
  bool inside(String p) {
    final a = win ? p.toLowerCase() : p;
    final r = win ? rootNorm.toLowerCase() : rootNorm;
    return a == r || a.startsWith('$r/');
  }

  final seen = <String>{};
  final out = <FileReference>[];
  for (final (_, ref) in found) {
    if (!inside(ref.path) || !seen.add(win ? ref.path.toLowerCase() : ref.path)) continue;
    // Windows desktops get their own separators back.
    out.add(win ? FileReference(ref.path.replaceAll('/', r'\'), ref.kind) : ref);
    if (out.length == 15) break;
  }
  return out;
}

/// ZCode's preview cards under a reply: one per referenced file, opening it
/// in the side pane.
class PreviewCards extends StatelessWidget {
  const PreviewCards({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final files = FileLinkScope.maybeOf(context);
    if (files == null) return const SizedBox.shrink();
    final refs = fileReferences(text, files.root);
    if (refs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(children: [
        for (final r in refs) _Card(ref: r, root: files.root, onOpen: () => files.onOpen(r.path)),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.ref, required this.root, required this.onOpen});
  final FileReference ref;
  final String root;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final label = switch (ref.kind) {
      PreviewKind.pdf => 'PDF',
      PreviewKind.pptx => s.cardPresentation,
      PreviewKind.docx => s.cardDocument,
      PreviewKind.sheet => s.cardWorkbook,
      PreviewKind.video => s.cardVideo,
      PreviewKind.audio => s.cardAudio,
      _ => '',
    };
    var rel = ref.path;
    final rootNorm = root.replaceFirst(RegExp(r'[\\/]$'), '');
    if (rel.startsWith(rootNorm) && rel.length > rootNorm.length) rel = rel.substring(rootNorm.length + 1);
    final dir = rel.contains(RegExp(r'[\\/]')) ? rel.substring(0, rel.lastIndexOf(RegExp(r'[\\/]'))) : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: z.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZRadius.lg),
          side: BorderSide(color: z.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: z.background, borderRadius: BorderRadius.circular(ZRadius.md)),
                child: Icon(previewIcon(ref.path), size: 22, color: z.foregroundSubtle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(ref.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foreground)),
                  const SizedBox(height: 2),
                  Text(dir.isEmpty ? label : '$label · $dir',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtlest)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: z.foregroundSubtlest),
            ]),
          ),
        ),
      ),
    );
  }
}
