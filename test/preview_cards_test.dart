import 'package:codezz/ui/conversation/preview_cards.dart';
import 'package:codezz/ui/side_pane/file_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = '/mnt/data/project';
  List<String> paths(String text, [String r = root]) => fileReferences(text, r).map((f) => f.path).toList();

  test('citation directives become cards and leave the text', () {
    const reply = '做好了。\n\n::zcode-file-citation{path="slides/deck.pptx" artifact_kind="presentation"}\n';
    expect(paths(reply), ['/mnt/data/project/slides/deck.pptx']);
    expect(fileReferences(reply, root).single.kind, PreviewKind.pptx);
    expect(stripFileCitations(reply), '做好了。\n\n');
    // A declared kind that doesn't match the extension is ignored.
    expect(paths(':zcode-file-citation{path="a.pdf" artifact_kind="workbook"}'), isEmpty);
  });

  test('links, file URLs, quoted and bare paths are found once each', () {
    expect(
      paths('See [the deck](out/deck.pptx), `report.docx`, file:///mnt/data/project/a%20b.pdf '
          'and data/sheet.xlsx. Again: out/deck.pptx'),
      [
        '/mnt/data/project/out/deck.pptx',
        '/mnt/data/project/report.docx',
        '/mnt/data/project/a b.pdf',
        '/mnt/data/project/data/sheet.xlsx',
      ],
    );
  });

  test('only previewable files inside the workspace', () {
    expect(paths('Edited `README.md` and `index.html`, see /tmp/x.pdf, ../up.pdf, ~/y.pdf'), isEmpty);
    expect(paths(r'Wrote `C:\work\app\out\a.pptx`.', r'C:\work\app'), [r'C:\work\app\out\a.pptx']);
  });
}
