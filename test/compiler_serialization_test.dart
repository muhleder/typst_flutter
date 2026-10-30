import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/src/rust/api/typst.dart' as api;
import 'package:typst_flutter/src/rust/frb_generated.dart';
import 'package:typst_flutter/typst_flutter.dart';

/// An engine whose `compile` blocks until the test releases it, so overlap is
/// observable.
class _GatedEngine extends Fake implements api.TypstEngine {
  final _gate = Completer<void>();
  int compileCalls = 0;
  bool disposed = false;

  void release() => _gate.complete();

  @override
  Future<api.CompiledDocument> compile({
    required String markup,
    required List<api.VirtualFile> files,
    required bool allowPackages,
    PlatformInt64? sysTime,
    Map<String, String>? inputs,
  }) async {
    compileCalls++;
    await _gate.future;
    return FakeCompiledDocument();
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class _EngineFactory extends Fake implements RustLibApi {
  _EngineFactory(this.engine);

  final api.TypstEngine engine;

  @override
  api.TypstEngine crateApiTypstTypstEngineNew() => engine;

  @override
  String crateApiTypstGetTypstVersion() => 'test';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeCompiledDocument extends Fake implements api.CompiledDocument {
  @override
  BigInt pageCount() => BigInt.from(1);

  @override
  api.PageInfo pageInfo({required BigInt index}) =>
      const api.PageInfo(widthPt: 100, heightPt: 100);

  @override
  List<api.TypstDiagnostic> warnings() => const [];

  @override
  void dispose() {}
}

void main() {
  test('compiles through one compiler run one at a time', () async {
    final engine = _GatedEngine();
    RustLib.initMock(api: _EngineFactory(engine));
    final compiler = await TypstCompiler.create();

    // What a widget does while the user types: a second compile starts before
    // the first has finished.
    final first = compiler.compile(source: '= One', allowPackages: false);
    final second = compiler.compile(source: '= Two', allowPackages: false);

    await Future<void>.delayed(Duration.zero);

    expect(
      engine.compileCalls,
      1,
      reason:
          'the second compile must wait: on web the synchronous package scans '
          'fail immediately if another call holds the engine',
    );

    engine.release();
    final documents = await Future.wait([first, second]);

    expect(documents, hasLength(2));
    expect(engine.compileCalls, 2);
  });
}
