import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/v4/ids.dart';
import '../core/zcode/server_info.dart';
import '../core/zcode/zcode_api.dart';

/// Limits of ZCode's composer attachments.
abstract final class AttachmentLimits {
  static const maxFiles = 8;
  static const maxInlineBytes = 20 * 1024 * 1024;
  static const chunkBytes = 384 * 1024;
  static const maxChunks = 64;
  static const maxTextChars = 64 * 1024;
}

const _textExtensions = {
  'cjs', 'conf', 'cpp', 'cs', 'css', 'csv', 'go', 'h', 'hpp', 'html', 'ini', 'java', 'js', 'json', 'jsx', //
  'log', 'md', 'mjs', 'py', 'rs', 'sh', 'sql', 'toml', 'ts', 'tsx', 'txt', 'xml', 'yaml', 'yml',
};

const _mimeByExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'svg': 'image/svg+xml',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'pdf': 'application/pdf',
  'json': 'application/json',
  'md': 'text/markdown',
  'html': 'text/html',
  'css': 'text/css',
  'csv': 'text/csv',
  'xml': 'text/xml',
  'txt': 'text/plain',
};

String attachmentExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot < 0 || dot == fileName.length - 1 ? '' : fileName.substring(dot + 1).toLowerCase();
}

String attachmentMime(String fileName) {
  final ext = attachmentExtension(fileName);
  return _mimeByExtension[ext] ?? (_textExtensions.contains(ext) ? 'text/plain' : 'application/octet-stream');
}

/// Images, video and PDF are sent as-is rather than as text.
bool attachmentIsInline(String fileName) {
  final mime = attachmentMime(fileName);
  return mime.startsWith('image/') || mime.startsWith('video/') || mime == 'application/pdf';
}

enum AttachmentStatus { waitingSession, queued, uploading, committing, ready, failed }

/// Why an attachment cannot be sent; the UI localises it.
enum AttachmentProblem { tooLarge, unreadable, uploadFailed }

/// One file picked in the composer, uploaded into the session with
/// `attachmentBeginV4` / `ChunkV4` / `CommitV4` (aborted on failure).
///
/// Images, video and PDF are sent as-is (up to 20 MB); text-like files are
/// truncated to 64K characters; other binaries cannot be attached.
class ComposerAttachment extends ChangeNotifier {
  ComposerAttachment._(this.fileName, this.mime, this.content, {this.problem})
      : status = problem == null ? AttachmentStatus.waitingSession : AttachmentStatus.failed;

  /// Reads a picked file the way ZCode's composer does.
  factory ComposerAttachment.fromFile(String fileName, Uint8List bytes, {required String truncatedNote}) {
    final mime = attachmentMime(fileName);
    if (attachmentIsInline(fileName)) {
      if (bytes.length > AttachmentLimits.maxInlineBytes) {
        return ComposerAttachment._(fileName, mime, null, problem: AttachmentProblem.tooLarge);
      }
      return ComposerAttachment._(fileName, mime, bytes);
    }
    final textLike = mime.startsWith('text/') || _textExtensions.contains(attachmentExtension(fileName));
    if (!textLike) return ComposerAttachment._(fileName, mime, null, problem: AttachmentProblem.unreadable);
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.length > AttachmentLimits.maxTextChars) {
      text = '${text.substring(0, AttachmentLimits.maxTextChars)}\n\n$truncatedNote';
    }
    return ComposerAttachment._(fileName, mime, Uint8List.fromList(utf8.encode(text)));
  }

  final String fileName;
  final String mime;
  final Uint8List? content;

  AttachmentStatus status;
  AttachmentProblem? problem;
  String? error;
  double progress = 0;

  /// `{ref, fileName, mime, bytes}` for `sendText.attachments`.
  Map<String, Object?>? ref;

  bool _cancelled = false;
  ({ZCodeApi api, WorkspaceRef ws, String sessionId, String uploadId})? _active;

  bool get isImage => mime.startsWith('image/');
  bool get isReady => status == AttachmentStatus.ready;
  bool get canRetry => status == AttachmentStatus.failed && content != null;

  void _set(AttachmentStatus s, {double? progress}) {
    status = s;
    if (progress != null) this.progress = progress;
    if (!_cancelled) notifyListeners();
  }

  /// Uploads into [sessionId]; failures end in [AttachmentStatus.failed]
  /// (a transient failure is retried once after 500 ms, as in ZCode).
  Future<void> upload(ZCodeApi api, WorkspaceRef ws, String sessionId) async {
    final bytes = content;
    if (bytes == null || status == AttachmentStatus.ready || _active != null) return;
    problem = null;
    error = null;
    for (var attempt = 0; attempt < 2 && !_cancelled; attempt++) {
      try {
        await _upload(api, ws, sessionId, bytes);
        return;
      } on _Permanent catch (e) {
        error = e.message;
        break;
      } catch (e) {
        error = '$e';
        if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    if (_cancelled) return;
    problem = AttachmentProblem.uploadFailed;
    _set(AttachmentStatus.failed);
  }

  Future<void> _upload(ZCodeApi api, WorkspaceRef ws, String sessionId, Uint8List bytes) async {
    final chunks = math.max(1, (bytes.length / AttachmentLimits.chunkBytes).ceil());
    if (chunks > AttachmentLimits.maxChunks) throw const _Permanent('too many chunks');
    final uploadId = 'upload-${uuidv4()}';
    _active = (api: api, ws: ws, sessionId: sessionId, uploadId: uploadId);
    _set(AttachmentStatus.uploading, progress: 0);
    try {
      final begin = await api.attachmentBegin(ws, sessionId, uploadId,
          fileName: fileName,
          mime: mime,
          totalBytes: bytes.length,
          totalChunks: chunks,
          checksum: 'sha256:${sha256.convert(bytes)}');
      Object? committed = begin['state'] == 'committed' ? begin['ref'] : null;
      if (committed == null) {
        var next = (begin['nextChunkIndex'] as num?)?.toInt() ?? 0;
        while (next < chunks) {
          if (_cancelled) return;
          final start = next * AttachmentLimits.chunkBytes;
          final end = math.min(start + AttachmentLimits.chunkBytes, bytes.length);
          final res = await api.attachmentChunk(
              ws, sessionId, uploadId, next, base64.encode(Uint8List.sublistView(bytes, start, end)));
          final reported = (res['nextChunkIndex'] as num?)?.toInt();
          if (reported != next + 1) throw StateError('unexpected nextChunkIndex $reported');
          next = reported!;
          _set(AttachmentStatus.uploading, progress: next / chunks);
        }
        _set(AttachmentStatus.committing, progress: 1);
        committed = (await api.attachmentCommit(ws, sessionId, uploadId))['ref'];
      }
      if (committed == null) throw StateError('no attachment ref');
      ref = {'ref': committed, 'fileName': fileName, 'mime': mime, 'bytes': bytes.length};
      _active = null;
      _set(AttachmentStatus.ready, progress: 1);
    } catch (_) {
      final a = _active;
      _active = null;
      if (a != null) await api.attachmentAbort(ws, sessionId, a.uploadId).catchError((Object _) {});
      rethrow;
    }
  }

  /// Removed from the composer: aborts an upload in flight.
  void cancel() {
    _cancelled = true;
    final a = _active;
    _active = null;
    if (a != null) {
      a.api.attachmentAbort(a.ws, a.sessionId, a.uploadId).catchError((Object _) {});
    }
  }
}

class _Permanent implements Exception {
  const _Permanent(this.message);
  final String message;
}
