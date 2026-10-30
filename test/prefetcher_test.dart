import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:typst_flutter/src/exceptions.dart';
import 'package:typst_flutter/src/packages.dart';
import 'package:typst_flutter/src/rust/api/typst.dart' as api;

/// Stands in for the Rust engine: records what the prefetcher asks of it.
class _FakeSource implements PackageSource {
  _FakeSource(this.referenced);

  final List<String> referenced;
  final cached = <String>{};
  final injected = <String, List<String>>{};
  final scannedFiles = <String>[];

  @override
  List<String> scanPackageSpecs({
    required String markup,
    required List<api.VirtualFile> files,
  }) {
    scannedFiles
      ..clear()
      ..addAll(files.map((f) => f.path));
    return referenced.where((spec) => !cached.contains(spec)).toList();
  }

  @override
  List<String> cachedPackageSpecs() => cached.toList();

  @override
  Future<List<String>> addPackageArchives(
    List<api.PackageArchive> archives,
  ) async {
    final unresolved = <String>[];
    for (final archive in archives) {
      cached.add(archive.spec);
      unresolved.addAll(injected[archive.spec] ?? const []);
    }
    return unresolved;
  }
}

void main() {
  group('PackagePrefetcher', () {
    test('downloads a referenced package once and injects its bytes', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.toString());
        return http.Response.bytes([1, 2, 3], 200);
      });
      final source = _FakeSource(['@preview/cetz:0.3.4']);
      final prefetcher = PackagePrefetcher(
        source,
        registryUrl: 'https://packages.typst.org',
        httpClient: client,
      );

      await prefetcher.prefetch(
        markup: '#import "@preview/cetz:0.3.4": *',
        files: const [],
      );

      expect(requested, [
        'https://packages.typst.org/preview/cetz-0.3.4.tar.gz',
      ]);
      expect(source.cached, {'@preview/cetz:0.3.4'});
    });

    test('surfaces a failed download with the spec and the url', () async {
      final client = MockClient((request) async => http.Response('nope', 404));
      final source = _FakeSource(['@preview/cetz:0.3.4']);
      final prefetcher = PackagePrefetcher(
        source,
        registryUrl: 'https://packages.typst.org',
        httpClient: client,
      );

      await expectLater(
        prefetcher.prefetch(
          markup: '#import "@preview/cetz:0.3.4": *',
          files: const [],
        ),
        throwsA(
          isA<TypstCompileException>().having(
            (e) => e.diagnostics.first.message,
            'message',
            allOf(
              contains('@preview/cetz:0.3.4'),
              contains('packages.typst.org'),
              contains('404'),
            ),
          ),
        ),
      );
    });

    test('follows the transitive specs the engine reports', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.path);
        return http.Response.bytes([1], 200);
      });
      final source = _FakeSource(['@preview/outer:0.1.0']);
      source.injected['@preview/outer:0.1.0'] = ['@preview/inner:0.2.0'];
      final prefetcher = PackagePrefetcher(
        source,
        registryUrl: 'https://packages.typst.org',
        httpClient: client,
      );

      await prefetcher.prefetch(
        markup: '#import "@preview/outer:0.1.0": *',
        files: const [],
      );

      expect(requested, [
        '/preview/outer-0.1.0.tar.gz',
        '/preview/inner-0.2.0.tar.gz',
      ]);
      expect(source.cached, {'@preview/outer:0.1.0', '@preview/inner:0.2.0'});
    });

    test('never re-downloads a package the engine already cached', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.path);
        return http.Response.bytes([1], 200);
      });
      final source = _FakeSource(['@preview/cetz:0.3.4']);
      final prefetcher = PackagePrefetcher(
        source,
        registryUrl: 'https://packages.typst.org',
        httpClient: client,
      );

      await prefetcher.prefetch(
        markup: '#import "@preview/cetz:0.3.4": *',
        files: const [],
      );
      await prefetcher.prefetch(
        markup: '#import "@preview/cetz:0.3.4": *',
        files: const [],
      );

      expect(requested, ['/preview/cetz-0.3.4.tar.gz']);
    });

    test(
      'passes the project files to the engine so includes are scanned',
      () async {
        final client = MockClient(
          (request) async => http.Response.bytes([1], 200),
        );
        final source = _FakeSource(['@preview/cetz:0.3.4']);
        final prefetcher = PackagePrefetcher(
          source,
          registryUrl: 'https://packages.typst.org',
          httpClient: client,
        );

        await prefetcher.prefetch(
          markup: '= Main',
          files: [
            api.VirtualFile(
              path: 'chapter.typ',
              bytes: utf8.encode('#import "@preview/cetz:0.3.4": *'),
            ),
          ],
        );

        expect(source.scannedFiles, ['chapter.typ']);
        expect(source.cached, {'@preview/cetz:0.3.4'});
      },
    );

    test('a package cycle terminates instead of looping forever', () async {
      final client = MockClient(
        (request) async => http.Response.bytes([1], 200),
      );
      final source = _FakeSource(['@preview/a:1.0.0']);
      source.injected['@preview/a:1.0.0'] = ['@preview/b:1.0.0'];
      source.injected['@preview/b:1.0.0'] = ['@preview/a:1.0.0'];
      final prefetcher = PackagePrefetcher(
        source,
        registryUrl: 'https://packages.typst.org',
        httpClient: client,
      );

      await prefetcher.prefetch(markup: '= Main', files: const []);

      expect(source.cached, {'@preview/a:1.0.0', '@preview/b:1.0.0'});
    });
  });
}
