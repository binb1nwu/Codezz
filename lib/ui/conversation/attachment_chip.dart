import 'package:flutter/material.dart';

import '../../state/attachments.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// A picked attachment above the composer text: a 48 px thumbnail for
/// images, otherwise a file chip with name and extension (or upload status).
/// A round × at the top right removes it.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.attachment, required this.onRemove, this.onRetry});
  final ComposerAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;

  String? _status(S s) {
    final a = attachment;
    return switch (a.status) {
      AttachmentStatus.waitingSession => null,
      AttachmentStatus.queued => s.uploadQueued,
      AttachmentStatus.uploading => s.uploading((a.progress * 100).round()),
      AttachmentStatus.committing => s.uploadCommitting,
      AttachmentStatus.ready => null,
      AttachmentStatus.failed => switch (a.problem) {
          AttachmentProblem.unreadable => s.attachmentUnreadable,
          _ => s.uploadFailed(a.error ?? ''),
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final a = attachment;
    final failed = a.status == AttachmentStatus.failed;
    final busy = a.status == AttachmentStatus.uploading || a.status == AttachmentStatus.committing;
    final status = _status(s);

    final Widget body;
    if (a.isImage && a.content != null) {
      body = Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ZRadius.lg),
          border: Border.all(color: failed ? z.destructive : z.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [
          Image.memory(a.content!, fit: BoxFit.cover, gaplessPlayback: true),
          if (busy || failed)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.45),
              child: Center(
                child: failed
                    ? const Text('!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))
                    : Text('${(a.progress * 100).round()}%',
                        style: const TextStyle(color: Colors.white, fontSize: ZText.xs)),
              ),
            ),
        ]),
      );
    } else {
      final ext = attachmentExtension(a.fileName).toUpperCase();
      body = Container(
        height: 48,
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.fromLTRB(6, 6, 24, 6),
        decoration: BoxDecoration(
          color: z.surface,
          borderRadius: BorderRadius.circular(ZRadius.lg),
          border: Border.all(color: failed ? z.destructive : z.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: z.surfaceHover, borderRadius: BorderRadius.circular(ZRadius.md)),
            child: busy
                ? const Center(child: ZSpinner(size: 14))
                : Icon(
                    a.mime == 'application/pdf' ? Icons.picture_as_pdf_outlined : Icons.description_outlined,
                    size: 18,
                    color: z.foregroundSubtle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: ZText.sm, color: z.foreground)),
              Text(status ?? ext,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: ZText.xs, color: failed ? z.destructive : z.foregroundSubtle)),
            ]),
          ),
        ]),
      );
    }

    return Tooltip(
      message: status ?? a.fileName,
      child: Stack(clipBehavior: Clip.none, children: [
        GestureDetector(
          onTap: (failed && a.canRetry) || a.status == AttachmentStatus.waitingSession ? onRetry : null,
          child: body,
        ),
        Positioned(
          top: -5,
          right: -5,
          child: Semantics(
            button: true,
            label: s.removeAttachment,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: z.primary, shape: BoxShape.circle),
                child: Icon(Icons.close_rounded, size: 12, color: z.primaryForeground),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
