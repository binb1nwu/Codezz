import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../l10n.dart';
import '../theme/tokens.dart';
import '../side_pane/file_preview.dart';
import 'common.dart';

/// Assistant/user Markdown with ZCode's reading hierarchy: body `ui-base`,
/// h1 `ui-xl`, h2 `ui-lg`, h3–h6 `ui-base` by weight, inline code mono `ui-sm`.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.data, {super.key, this.selectable = true, this.dense = false});

  final String data;
  final bool selectable;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final body = TextStyle(fontSize: ZText.base, height: dense ? 1.5 : 1.65, color: z.foreground);
    final sheet = MarkdownStyleSheet(
      p: body,
      a: body.copyWith(color: z.link),
      h1: body.copyWith(fontSize: ZText.xl, fontWeight: FontWeight.w600, height: 1.4),
      h2: body.copyWith(fontSize: ZText.lg, fontWeight: FontWeight.w600, height: 1.4),
      h3: body.copyWith(fontWeight: FontWeight.w600),
      h4: body.copyWith(fontWeight: FontWeight.w600),
      h5: body.copyWith(fontWeight: FontWeight.w500),
      h6: body,
      h1Padding: const EdgeInsets.only(top: 8),
      h2Padding: const EdgeInsets.only(top: 6),
      em: body.copyWith(fontStyle: FontStyle.italic),
      strong: body.copyWith(fontWeight: FontWeight.w600),
      del: body.copyWith(decoration: TextDecoration.lineThrough),
      listBullet: body,
      blockquote: body.copyWith(color: z.foregroundSubtle),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: z.borderHover, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
      code: TextStyle(
        fontFamily: zMonoFamily,
        fontFamilyFallback: zMonoFallback,
        fontSize: ZText.sm,
        color: z.foreground,
        backgroundColor: z.surfaceHover,
      ),
      tableHead: body.copyWith(color: z.foregroundSubtle, fontWeight: FontWeight.w500),
      tableHeadAlign: TextAlign.left,
      tableBody: body,
      tableBorder: TableBorder(
        horizontalInside: BorderSide(color: z.border),
        top: BorderSide(color: z.border),
        bottom: BorderSide(color: z.border),
        left: BorderSide(color: z.border),
        right: BorderSide(color: z.border),
        borderRadius: BorderRadius.circular(ZRadius.xl),
      ),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: z.border))),
      blockSpacing: dense ? 6 : 12,
      codeblockDecoration: const BoxDecoration(),
      codeblockPadding: EdgeInsets.zero,
    );
    return MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: sheet,
      extensionSet: md.ExtensionSet.gitHubWeb,
      builders: {'pre': _CodeBlockBuilder()},
      softLineBreak: true,
      // Local paths open in the code viewer; web links are left alone.
      onTapLink: (_, href, __) {
        if (href != null) FileLinkScope.maybeOf(context)?.openLink(href);
      },
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    var language = '';
    final first = element.children?.firstOrNull;
    if (first is md.Element) {
      final cls = first.attributes['class'] ?? '';
      if (cls.startsWith('language-')) language = cls.substring(9);
    }
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return CodeBlock(code: code, language: language);
  }
}

/// Monospace block with a header (language + copy), horizontally scrollable.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language = '', this.maxHeight});

  final String code;
  final String language;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final text = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: SelectableText(
        code,
        style: TextStyle(
          fontFamily: zMonoFamily,
          fontFamilyFallback: zMonoFallback,
          fontSize: 13,
          height: 1.5,
          color: z.foreground,
        ),
      ),
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: z.codeBackground,
        borderRadius: BorderRadius.circular(ZRadius.xl),
        border: Border.all(color: z.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
          child: Row(children: [
            Expanded(
              child: Text(language,
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
            ),
            ZIconButton(
              icon: Icons.copy_rounded,
              iconSize: 14,
              size: 28,
              tooltip: S.of(context).copy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                showToast(context, S.of(context).copied);
              },
            ),
          ]),
        ),
        if (maxHeight != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight!),
            child: SingleChildScrollView(child: text),
          )
        else
          text,
      ]),
    );
  }
}
