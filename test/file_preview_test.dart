import 'dart:typed_data';

import 'package:codezz/core/zcode/zcode_api.dart';
import 'package:codezz/state/side_pane.dart';
import 'package:codezz/ui/conversation/rows.dart';
import 'package:codezz/ui/side_pane/file_preview.dart';
import 'package:codezz/ui/theme/tokens.dart';
import 'package:codezz/ui/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(Widget home) => MaterialApp(theme: buildZTheme(Brightness.light), home: Scaffold(body: home));

  group('local links', () {
    test('resolve against the workspace like ZCode', () {
      const root = '/mnt/data/project';
      expect(resolveLocalPath(root, 'eval/run.sh'), '/mnt/data/project/eval/run.sh');
      expect(resolveLocalPath(root, './eval/run.sh:12'), '/mnt/data/project/eval/run.sh');
      expect(resolveLocalPath(root, 'a/../b.py#L3'), '/mnt/data/project/b.py');
      expect(resolveLocalPath(root, '/mnt/data/project/x.md'), '/mnt/data/project/x.md');
      expect(resolveLocalPath(root, '/tmp/log.txt'), '/tmp/log.txt');
      expect(resolveLocalPath(root, '/src/main.dart'), '/mnt/data/project/src/main.dart');
      expect(resolveLocalPath(root, 'file:///home/u/a%20b.txt'), '/home/u/a b.txt');
      expect(resolveLocalPath(root, '../../etc/passwd'), isNull);
      expect(resolveLocalPath(root, 'https://z.ai'), isNull);
      expect(resolveLocalPath(root, '#section'), isNull);
      expect(resolveLocalPath(r'C:\work\app', 'lib/main.dart'), r'C:\work\app\lib\main.dart');
      expect(resolveLocalPath(r'C:\work\app', r'D:\x.txt'), r'D:\x.txt');
    });

    test('file kinds follow the extension', () {
      expect(previewKind('/a/b.PNG'), PreviewKind.image);
      expect(previewKind('/a/b.mp4'), PreviewKind.video);
      expect(previewKind('/a/b.flac'), PreviewKind.audio);
      expect(previewKind('/a/README.md'), PreviewKind.markdown);
      expect(previewKind('/a/b.pdf'), PreviewKind.pdf);
      expect(previewKind('/a/b.xlsx'), PreviewKind.sheet);
      expect(previewKind('/a/deck.PPTX'), PreviewKind.pptx);
      expect(previewKind('/a/b.docx'), PreviewKind.docx);
      expect(previewKind('/a/b.doc'), PreviewKind.legacyOffice);
      expect(previewKind('/a/Makefile'), PreviewKind.text);
    });
  });

  test('front matter shows as code, not a heading', () {
    expect(frontMatterAsCode('---\nname: x\ntype: y\n---\n# Body'), '```yaml\nname: x\ntype: y\n```\n# Body');
    expect(frontMatterAsCode('# Plain\n---\n'), '# Plain\n---\n');
  });

  test('a file opens once per path, in the side pane', () {
    final pane = SidePane();
    pane.openFile('/w/a.dart');
    pane.openFile('/w/b.dart');
    pane.openFile('/w/a.dart');
    expect(pane.tabs.map((t) => t.title), ['a.dart', 'b.dart']);
    expect(pane.active!.path, '/w/a.dart');
    expect(pane.visible, isTrue);
    pane.dispose();
  });

  group('code viewer', () {
    testWidgets('text: numbered lines and the path menu', (tester) async {
      final api = _FakeApi({'content': 'void main() {\n  print(1);\n}\n', 'isBinary': false, 'truncated': false});
      await tester.pumpWidget(app(FilePreview(api: api, path: '/w/lib/main.dart', root: '/w')));
      expect(find.text('Loading file...'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('  print(1);'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(api.reads, ['/w/lib/main.dart']);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Wrap lines'), findsOneWidget);
      expect(find.text('Copy relative path'), findsOneWidget);
    });

    testWidgets('markdown renders, with the source a tap away', (tester) async {
      final api = _FakeApi({'content': '# Title\n\nbody', 'isBinary': false, 'truncated': false});
      await tester.pumpWidget(app(FilePreview(api: api, path: '/w/README.md', root: '/w')));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownView), findsOneWidget);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show source'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownView), findsNothing);
      expect(find.text('# Title'), findsOneWidget);
    });

    testWidgets('binary, too large and missing files say so', (tester) async {
      for (final (res, message) in [
        ({'content': '', 'isBinary': true, 'truncated': false}, 'binary data'),
        ({'content': 'x', 'isBinary': false, 'truncated': true}, '256 KB'),
        (null, 'does not exist'),
      ]) {
        await tester.pumpWidget(app(FilePreview(
          key: UniqueKey(),
          api: _FakeApi(res, error: res == null ? 'ENOENT: no such file or directory' : null),
          path: '/w/x.bin',
          root: '/w',
        )));
        await tester.pumpAndSettle();
        expect(find.textContaining(message), findsOneWidget);
      }
    });

    testWidgets('documents over 64 MB are not copied to the phone', (tester) async {
      final api = _FakeApi(null, size: 65 * 1024 * 1024);
      await tester.pumpWidget(app(FilePreview(api: api, path: '/w/deck.pptx', root: '/w')));
      await tester.pumpAndSettle();
      expect(find.textContaining('64 MB'), findsOneWidget);
      expect(api.ranges, isEmpty);
    });

    testWidgets('legacy .doc says it cannot be previewed', (tester) async {
      await tester.pumpWidget(app(FilePreview(api: _FakeApi(null), path: '/w/old.doc', root: '/w')));
      await tester.pumpAndSettle();
      expect(find.text('This Office file cannot be previewed.'), findsOneWidget);
    });
  });

  testWidgets('a Read call and a local link open the file', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(app(FileLinkScope(
      root: '/w',
      onOpen: opened.add,
      child: const Column(children: [
        ToolCallRow(row: {
          'toolName': 'Read',
          'status': 'completed',
          'input': {'file_path': '/w/lib/a.dart'},
        }),
        MarkdownView('See [the notes](docs/notes.md) or [the site](https://z.ai).'),
      ]),
    )));
    await tester.tap(find.text('Read'));
    await tester.pump();
    expect(opened, ['/w/lib/a.dart']);
  });

  test('links in Markdown resolve through the scope', () {
    final opened = <String>[];
    final scope = FileLinkScope(root: '/w', onOpen: opened.add, child: const SizedBox());
    expect(scope.openLink('docs/notes.md'), isTrue);
    expect(scope.openLink('https://z.ai'), isFalse);
    expect(opened, ['/w/docs/notes.md']);
  });
}

class _FakeApi implements ZCodeApi {
  _FakeApi(this.text, {this.error, this.size});
  final Map<String, dynamic>? text;
  final String? error;
  final int? size;
  final List<String> reads = [];
  final List<int> ranges = [];

  @override
  Future<Map<String, dynamic>> statFile(String path) async => {'type': 'file', 'size': size};

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    ranges.add(offset);
    return Uint8List(0);
  }

  @override
  Future<Map<String, dynamic>> readTextFile(String path, {int offset = 0, int length = 262144}) async {
    reads.add(path);
    if (error != null) throw StateError(error!);
    return text!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
