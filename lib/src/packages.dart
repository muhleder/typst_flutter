/// Package prefetching for platforms that cannot download during compilation.
///
/// Typst resolves packages from inside `World::file`, which is synchronous:
/// a browser `fetch` can never run there. So on web the packages are fetched
/// *before* `compile()` and injected into the engine's resolver cache, which
/// `compile()` then reads synchronously. Native platforms keep downloading in
/// Rust; this file is not used there.
library;

import 'package:http/http.dart' as http;
import 'package:typst_flutter/src/exceptions.dart';
import 'package:typst_flutter/src/rust/api/typst.dart' as api;

/// The parts of `TypstEngine` the prefetcher needs.
abstract interface class PackageSource {
  /// `@namespace/name:version` specs referenced by the markup or its files.
  List<String> scanPackageSpecs({
    required String markup,
    required List<api.VirtualFile> files,
  });

  /// Specs already resident in the engine's cache.
  List<String> cachedPackageSpecs();

  /// Injects archives and returns the specs that are still unresolved.
  Future<List<String>> addPackageArchives(List<api.PackageArchive> archives);
}

/// [PackageSource] backed by the Rust engine.
final class EnginePackageSource implements PackageSource {
  /// Wraps the Rust engine.
  EnginePackageSource(this._engine);

  final api.TypstEngine _engine;

  @override
  List<String> scanPackageSpecs({
    required String markup,
    required List<api.VirtualFile> files,
  }) => _engine.scanPackageSpecs(markup: markup, files: files);

  @override
  List<String> cachedPackageSpecs() => _engine.cachedPackageSpecs();

  @override
  Future<List<String>> addPackageArchives(
    List<api.PackageArchive> archives,
  ) => _engine.addPackageArchives(archives: archives);
}

/// Downloads the `@preview/...` packages a document references and injects
/// them into the engine, following transitive dependencies.
final class PackagePrefetcher {
  /// Creates a prefetcher for the given package source.
  ///
  /// [registryUrl] is the registry base URL (defaults to the Typst one);
  /// [httpClient] allows callers and tests to supply their own client;
  /// [maxRounds] bounds the transitive walk so a package cycle cannot spin.
  PackagePrefetcher(
    this._source, {
    required String registryUrl,
    http.Client? httpClient,
    this.maxRounds = 8,
  }) : _registryUrl = registryUrl.endsWith('/')
           ? registryUrl.substring(0, registryUrl.length - 1)
           : registryUrl,
       _httpClient = httpClient ?? http.Client();

  final PackageSource _source;
  final String _registryUrl;
  final http.Client _httpClient;

  /// Upper bound on how many transitive rounds are followed.
  final int maxRounds;

  /// Fetches every package the markup and its files reference, in dependency
  /// order, and reports failures as [TypstCompileException]s.
  Future<void> prefetch({
    required String markup,
    required List<api.VirtualFile> files,
  }) async {
    final cached = _source.cachedPackageSpecs().toSet();
    final pending = <String>[];

    void queue(String spec) {
      if (!cached.contains(spec) && !pending.contains(spec)) pending.add(spec);
    }

    _source.scanPackageSpecs(markup: markup, files: files).forEach(queue);

    var rounds = 0;
    while (pending.isNotEmpty && rounds < maxRounds) {
      rounds++;
      final batch = List<String>.of(pending);
      pending.clear();

      final archives = await Future.wait(batch.map(_download));
      final unresolved = await _source.addPackageArchives(archives);
      cached.addAll(batch);
      unresolved.forEach(queue);
    }
  }

  Future<api.PackageArchive> _download(String spec) async {
    final url = _urlFor(spec);
    final http.Response response;
    try {
      response = await _httpClient.get(Uri.parse(url));
    } on Exception catch (error) {
      throw _failure(spec, url, 'request failed: $error');
    }

    if (response.statusCode != 200) {
      throw _failure(spec, url, 'HTTP ${response.statusCode}');
    }

    return api.PackageArchive(spec: spec, bytes: response.bodyBytes);
  }

  /// `@namespace/name:version` becomes `{registry}/{namespace}/{name}-{version}.tar.gz`.
  String _urlFor(String spec) {
    final bare = spec.startsWith('@') ? spec.substring(1) : spec;
    final slash = bare.indexOf('/');
    if (slash <= 0) {
      throw _failure(spec, spec, 'not a fully qualified package spec');
    }
    final namespace = bare.substring(0, slash);
    final nameAndVersion = bare.substring(slash + 1);
    final colon = nameAndVersion.lastIndexOf(':');
    if (colon <= 0) {
      throw _failure(spec, spec, 'not a fully qualified package spec');
    }
    final name = nameAndVersion.substring(0, colon);
    final version = nameAndVersion.substring(colon + 1);
    return '$_registryUrl/$namespace/$name-$version.tar.gz';
  }

  TypstCompileException _failure(String spec, String url, String reason) =>
      TypstCompileException(
        'Failed to load Typst package $spec from $url ($reason)',
        diagnostics: [
          api.TypstDiagnostic(
            severity: api.TypstSeverity.error,
            message: 'Failed to download package $spec from $url ($reason)',
            hints: const [
              'Check the package name and version against packages.typst.org.',
              'Set allowPackages: false to compile without packages.',
            ],
          ),
        ],
      );
}
