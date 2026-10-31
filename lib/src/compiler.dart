import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:http/http.dart' as http;
import 'package:typst_flutter/src/bridge/bridge.dart';
import 'package:typst_flutter/src/call_queue.dart';
import 'package:typst_flutter/src/config.dart';
import 'package:typst_flutter/src/document.dart';
import 'package:typst_flutter/src/exceptions.dart';
import 'package:typst_flutter/src/files.dart';
import 'package:typst_flutter/src/fonts.dart';
import 'package:typst_flutter/src/packages.dart';
import 'package:typst_flutter/src/rust/api/typst.dart' as api;
import 'package:typst_flutter/src/rust/frb_generated.dart';

/// The Typst compiler bridge.
///
/// Create a single instance per app or per compiler configuration and reuse
/// it — construction is lightweight; the heavy native library is loaded once
/// when [RustLib.init] is called.
///
/// ```dart
/// final compiler = await TypstCompiler.create(
///   fonts: FontSource.assets(['assets/fonts/Roboto.ttf']),
/// );
///
/// // Compile to a lightweight document handle
/// final doc = await compiler.compile(source: myMarkup);
///
/// // Lazily render pages or export PDF
/// final pdfBytes = await doc.exportPdf();
/// final result = await doc.renderRaster(pageIndex: 0);
/// ```
class TypstCompiler {
  TypstCompiler._({
    required api.TypstEngine engine,
    required String packageRegistryUrl,
    required http.Client httpClient,
  }) : _engine = engine,
       _packageRegistryUrl = packageRegistryUrl,
       _httpClient = httpClient;

  /// The underlying stateful Rust engine.
  final api.TypstEngine _engine;

  final String _packageRegistryUrl;
  final http.Client _httpClient;

  /// Runs [action] through the queue every call into Rust shares.
  ///
  /// It used to be one queue per compiler, for the engine's own state:
  /// `compile` mutates the world before running, and a widget can legitimately
  /// fire an un-awaited recompile on every keystroke. The reason is bigger than
  /// one engine - typst's memo cache is process-wide behind locks a browser
  /// cannot park on, so a compile here and a page render on another engine must
  /// not overlap either - and the queue lives in `call_queue.dart` for it.
  Future<T> _serialize<T>(Future<T> Function() action) => rustCalls.run(action);

  /// Releases the native resources associated with this compiler.
  ///
  /// After calling this, the compiler instance is no longer usable and any
  /// further calls to its methods will throw an error.
  void dispose() {
    _engine.dispose();
  }

  /// Creates a [TypstCompiler] and initialises the native bridge.
  ///
  /// [fonts] — additional font files to make available to the Typst compiler.
  /// These are added on top of the bundled core fonts (`Libertinus Serif`,
  /// `DejaVu Sans Mono`, and `NewCM Math`).
  ///
  /// This is safe to call multiple times; the native library is only
  /// initialised once.
  ///
  /// On web the WebAssembly bundle is loaded from `pkg/typst_flutter` relative
  /// to the page, which is where `dart run typst_flutter:setup --web` puts it.
  ///
  /// [packageRegistryUrl] and [httpClient] only affect web builds, where
  /// packages are downloaded in Dart before compilation (a browser cannot
  /// fetch inside `World::file`). On native platforms the registry URL comes
  /// from `TYPST_PACKAGE_URL` or defaults to `https://packages.typst.org`.
  static Future<TypstCompiler> create({
    FontSource? fonts,
    String? packageRegistryUrl,
    http.Client? httpClient,
  }) async {
    try {
      await initWithOptionalWebModule();
      // flutter_rust_bridge throws a StateError if init() is called more than
      // once. We ignore this specific error to remain robust in tests.
      // ignore: avoid_catching_errors
    } on StateError catch (e) {
      // flutter_rust_bridge throws a StateError both when init() runs twice
      // and when the wasm bundle was built from a different version.
      if (e.message.contains('twice')) {
        // already initialised; fine
      } else if (kIsWeb) {
        throw describeInitFailure(e);
      } else {
        rethrow;
      }
    } on TypstWebSetupException {
      rethrow;
    } on Object catch (e) {
      if (!kIsWeb) rethrow;
      throw describeInitFailure(e);
    }

    final engine = api.TypstEngine();
    if (fonts != null) {
      final fontBytes = await fonts.load();
      if (fontBytes.isNotEmpty) {
        await rustCalls.run(() => engine.addFonts(fontData: fontBytes));
      }
    }
    return TypstCompiler._(
      engine: engine,
      packageRegistryUrl: packageRegistryUrl ?? TypstFlutter.packageRegistryUrl,
      httpClient: httpClient ?? http.Client(),
    );
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Adds more fonts to this compiler instance.
  Future<void> addFonts(FontSource fonts) async {
    final fontBytes = await fonts.load();
    if (fontBytes.isNotEmpty) {
      await _serialize(() => _engine.addFonts(fontData: fontBytes));
    }
  }

  PlatformInt64? _dateTimeToSysTime(DateTime? date) {
    if (date == null) return null;
    return PlatformInt64Util.from((date.millisecondsSinceEpoch / 1000).round());
  }

  /// Compiles Typst [source] markup into a lightweight document handle.
  ///
  /// Returns a [TypstDocument] which can be used to query page dimensions,
  /// lazily render raster/SVG pages, or export the full document to PDF.
  ///
  /// [allowPackages] controls whether packages referenced via
  /// `#import "@preview/..."` will be automatically downloaded from
  /// `packages.typst.org` and cached in memory. Defaults to `true`.
  /// Set to `false` for offline-only compilation or to prevent network access.
  Future<TypstDocument> compile({
    required String source,
    FileSource? files,
    DateTime? date,
    Map<String, String>? inputs,
    bool allowPackages = true,
  }) async {
    // Reading the files and, on the web, downloading the packages the markup
    // names happen outside the queue: they are Dart work, and holding the one
    // slot the whole library shares through a download would stall every other
    // call behind it. What is queued is the engine call itself, which is what
    // contends.
    final virtualFiles = await _buildVirtualFiles(files);
    try {
      if (kIsWeb && allowPackages) {
        await PackagePrefetcher(
          EnginePackageSource(_engine),
          registryUrl: _packageRegistryUrl,
          httpClient: _httpClient,
        ).prefetch(markup: source, files: virtualFiles);
      }
      final inner = await _serialize(
        () => _engine.compile(
          markup: source,
          files: virtualFiles,
          sysTime: _dateTimeToSysTime(date),
          inputs: inputs,
          allowPackages: allowPackages,
        ),
      );
      return TypstDocument.fromInner(inner);
    } on api.TypstCompileError catch (e) {
      throw TypstCompileException(
        'Compilation failed',
        diagnostics: e.diagnostics,
      );
    } on TypstCompileException {
      // Already actionable (a package download failure names the spec).
      rethrow;
    } catch (e) {
      throw TypstCompileException('$e');
    }
  }

  /// Returns the version string of the embedded Typst compiler engine.
  String get compilerVersion => api.getTypstVersion();

  /// Queries the compiled [document] using a Typst [selector] string.
  ///
  /// Returns a JSON string containing the queried elements (e.g. headings).
  Future<String> query({
    required TypstDocument document,
    required String selector,
  }) => _serialize(
    () => _engine.query(document: document.inner, selector: selector),
  );

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<List<api.VirtualFile>> _buildVirtualFiles(FileSource? source) async {
    final effectiveSource = source ?? const FileSource.none();
    final map = await effectiveSource.load();
    return map.entries
        .map((e) => api.VirtualFile(path: e.key, bytes: e.value))
        .toList();
  }
}
