// Browser test for the WebAssembly path. Run with:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/web_test.dart -d chrome --wasm \
//     --web-header=Cross-Origin-Opener-Policy=same-origin \
//     --web-header=Cross-Origin-Embedder-Policy=require-corp
//
// `example/web/pkg` must exist (run `just build-web` at the repo root, or
// `dart run typst_flutter:setup --web` in this directory).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:typst_flutter/typst_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compiles, renders and exports a document', (tester) async {
    final compiler = await TypstCompiler.create();
    final document = await compiler.compile(
      source: '= Hello\n#pagebreak()\nPage two',
      allowPackages: false,
    );

    expect(document.pageCount, 2);
    expect(document.pageInfo(0).widthPt, greaterThan(0));

    final svg = await document.renderSvg(0);
    expect(svg, contains('<svg'));

    final raster = await document.renderRaster(pageIndex: 0);
    expect(raster.width, greaterThan(0));
    expect(raster.height, greaterThan(0));
    expect(raster.bytes.length, raster.width * raster.height * 4);

    // The export runs on a pool the calling thread owns, so krilla's deferred
    // chunks have somewhere to run: it must answer a whole PDF, not hang.
    expect(TypstDocument.supportsPdfExport, isTrue);
    final pdf = await document.exportPdf();
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    expect(String.fromCharCodes(pdf.skip(pdf.length - 6)).trim(), '%%EOF');

    document.dispose();
    compiler.dispose();
  });

  testWidgets('TypstView renders a page in the browser', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TypstView.source(source: '= Hi')),
      ),
    );

    // TypstView shows a progress indicator while compiling, so pumpAndSettle
    // would never settle; poll instead.
    var rendered = false;
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (tester.takeException() != null) break;
      if (find.byType(TypstView).evaluate().isNotEmpty) rendered = true;
    }

    expect(rendered, isTrue);
    expect(tester.takeException(), isNull);
  });

  // Hits packages.typst.org: this is the only test that exercises the whole
  // prefetch-on-web path (scan in Rust, download in Dart, inject, compile).
  testWidgets('a @preview import is prefetched and compiled', (tester) async {
    final compiler = await TypstCompiler.create();
    final document = await compiler.compile(
      source: '''
#import "@preview/cetz:0.3.4": canvas, draw
#canvas({
  import draw: *
  line((0, 0), (1, 1))
})
''',
    );

    // Would have thrown TypstCompileException (NotPrefetched) without the
    // Dart-side prefetch, since a browser cannot fetch inside World::file.
    expect(document.pageCount, 1);
    document.dispose();
    compiler.dispose();
  });
}
