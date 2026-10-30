import 'package:typst_flutter/src/rust/api/typst.dart' as api;

/// Base class for all Typst-related exceptions.
class TypstException implements Exception {
  /// Creates a [TypstException] with the given error [message].
  const TypstException(this.message);

  /// The error message describing the exception.
  final String message;
  @override
  String toString() => 'TypstException: $message';
}

/// Thrown when the Typst compiler fails to compile a document.
class TypstCompileException extends TypstException {
  /// Creates a [TypstCompileException] with the given [message].
  const TypstCompileException(super.message, {this.diagnostics = const []});

  /// Structured diagnostics from the Typst compiler.
  ///
  /// Each entry carries severity, the error message, optional hints,
  /// and — after FRB codegen — optional 1-based source location fields
  /// (`spanStart` / `spanEnd`) giving the exact line and column of
  /// the offending range in the Typst markup.
  final List<api.TypstDiagnostic> diagnostics;

  @override
  String toString() {
    if (diagnostics.isEmpty) return super.toString();

    final buffer = StringBuffer('Typst Compilation Errors:\n');
    for (final diag in diagnostics) {
      final severity = diag.severity.name.toUpperCase();
      final loc = diag.spanStart;
      final locStr = loc != null ? '${loc.line}:${loc.column} \u2014 ' : '';
      buffer.writeln('[$severity] $locStr${diag.message}');
      for (final hint in diag.hints) {
        buffer.writeln('  Hint: $hint');
      }
    }
    return buffer.toString().trim();
  }
}

/// Thrown when rendering or exporting a page of a compiled document fails.
///
/// This is distinct from [TypstCompileException]: a [TypstRenderException]
/// means compilation succeeded but a subsequent render or export operation
/// failed (e.g. an internal Typst SVG/PDF error).
///
/// Caller-side mistakes such as passing an invalid page index will throw a
/// [RangeError] instead, consistent with standard Dart collection behaviour.
class TypstRenderException extends TypstException {
  /// Creates a [TypstRenderException] with the given [message].
  const TypstRenderException(super.message);

  @override
  String toString() => 'TypstRenderException: $message';
}

/// Thrown when the WebAssembly bundle that powers web builds is missing,
/// stale, or failed to load.
///
/// Web builds load `pkg/typst_flutter.js` and `pkg/typst_flutter_bg.wasm`
/// from the host app's `web/` directory. Creating the artifacts and keeping
/// them in step with this package version is done by
/// `dart run typst_flutter:setup --web`.
class TypstWebSetupException extends TypstException {
  /// Creates a [TypstWebSetupException].
  const TypstWebSetupException(super.message, {this.cause});

  /// The underlying error, kept for debugging.
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('TypstWebSetupException: $message');
    if (cause != null) buffer.write('\nCaused by: $cause');
    return buffer.toString();
  }
}

/// Maps a failure from the web bridge initialisation into an actionable
/// [TypstWebSetupException].
///
/// Two failures account for almost every real case: the bundle in `web/pkg`
/// was built by a different version of this package (FRB's content-hash or
/// codegen-version check), and the page was served without the headers the
/// threaded wasm needs.
TypstWebSetupException describeInitFailure(Object error) {
  // flutter_rust_bridge throws StateError('Content hash …') and
  // StateError('<stem>\'s codegen version …'), both capitalised.
  final text = error.toString().toLowerCase();
  final stale =
      text.contains('content hash') ||
      text.contains('codegen') ||
      text.contains('out-of-sync');

  if (stale) {
    return TypstWebSetupException(
      'The WebAssembly bundle in web/pkg is stale: it was built from a '
      'different version of typst_flutter than the Dart code running now. '
      'Re-run: dart run typst_flutter:setup --web',
      cause: error,
    );
  }

  return TypstWebSetupException(
    'Failed to initialise the Typst WebAssembly module. Check that '
    'web/pkg/typst_flutter.js and web/pkg/typst_flutter_bg.wasm are served, '
    'and that the page is served with the headers the threaded wasm needs: '
    'Cross-Origin-Opener-Policy: same-origin and '
    'Cross-Origin-Embedder-Policy: require-corp. '
    'If the files are missing, run: dart run typst_flutter:setup --web',
    cause: error,
  );
}
