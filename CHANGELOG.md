## 3.1.0-beta.1

### New Features

- **Flutter Web support (WebAssembly)**: the whole API now works in the browser,
  in apps built with `flutter build web --wasm` (dart2wasm) and with the
  JavaScript compiler.
  - `TypstCompiler`, `TypstDocument`, `TypstView`, `TypstDocumentViewer`, SVG
    and raster rendering run from a threaded wasm build; compilation happens on
    Flutter Rust Bridge's worker pool, so the UI thread is never blocked.
  - `#import "@preview/..."` works on web: packages are scanned in Rust,
    downloaded in Dart and injected into the compiler before it runs, because a
    browser cannot fetch from inside Typst's synchronous file lookup. Failures
    surface as `TypstCompileException` naming the package and URL.
  - New `TypstFlutter.configure(packageRegistryUrl:)` points web builds at a
    registry mirror.
  - New `TypstWebSetupException` explains a missing or stale wasm bundle and the
    `dart run typst_flutter:setup --web` command that fixes it.
  - `dart run typst_flutter:setup --web` downloads the wasm bundle into the
    app's `web/pkg` (verified against `SHA256SUMS`); it is opt-in, so native-only
    apps never receive web files.
  - New `--local` and `--from <dir>` modes install artifacts built on your own
    machine instead of a release — `rust/target/**/release` and
    `example/web/pkg` for `--local`, any release-shaped directory for `--from`.
    Nothing is downloaded and no checksum applies. This is what a fork needs
    before it has published a release.
  - `setup` now resolves its release repository from the package's
    `pubspec.yaml` `repository:` URL (overridable with `--repo owner/name` or
    `TYPST_FLUTTER_REPO`), so a fork stops asking the upstream repository for
    releases it never published.
  - The web build requires cross-origin isolation:
    `Cross-Origin-Opener-Policy: same-origin` and
    `Cross-Origin-Embedder-Policy: require-corp`.
  - Every asynchronous call into Rust now goes through one queue - `compile`,
    `addFonts`, `query`, `renderRaster`, `renderSvg`, `exportPdf`, across every
    compiler and document. Without it, two overlapping calls in a browser did
    not wait for each other: `parking_lot`'s wasm parker panics rather than
    blocking and typst's memo cache is process-wide, so a compile issued while a
    page was being rendered trapped the wasm instance and lost the call. This is
    the ordinary case for a preview - typing while a page renders - and it failed
    silently.
  - PDF export works on web. `typst_pdf` -> `krilla` hands its work to
    `rayon::spawn` and blocks on the result, and a browser cannot spawn rayon
    workers - rayon's wasm fallback pool is a single worker owned by whichever
    thread first touched rayon, so an export issued from any other thread blocked
    for ever with no error (reported against an app whose page used EB Garamond;
    documents small enough for `rayon::yield_now` to complete inline appeared to
    work). The conversion now runs inside a pool the calling thread owns, so the
    deferred work has a thread to run on: the export is synchronous and
    single-threaded on web. `TypstDocument.supportsPdfExport` is `true`
    everywhere.
  - Other web limitations: 1 GiB wasm memory ceiling, Typst layout runs
    single-threaded inside one worker, and the bundle is 22.7 MB raw
    (7.3 MB brotli).
- Dependency: `flutter_rust_bridge` **2.14.0-beta.2** (pinned). 2.14 is the first
  release with Dart-Wasm support; a stable `typst_flutter` 3.1.0 will follow once
  FRB 2.14.0 is stable.

### Breaking-ish

- `TypstCompiler` no longer implements `dart:ffi`'s `Finalizable`. The marker
  interface made `lib/` unbuildable for web; `dispose()` is unchanged and remains
  the way to release native resources.
- `[profile.release]` now uses fat LTO, which makes release builds slower to
  link and smaller to ship.

## 3.0.0

### New Features & Performance

- **Incremental Compilation Cache**:
  - Replaced full AST re-parsing with Typst's incremental `Source::edit` and `comemo` memoization.
  - Secondary project files and package files are cached across compilations and incrementally edited when modified.
  - Sub-30ms rebuild times during interactive editing and live document typing in Flutter.
- **Typst Package Resolution**: `#import "@preview/..."` is now supported out of the box!
  - Packages are automatically fetched from `packages.typst.org`, decompressed, and cached in memory across the engine's lifecycle.
  - Transitive dependencies between packages are resolved and loaded automatically.
  - Added `allowPackages` (default `true`) parameter to `TypstCompiler.compile()`. Set to `false` for offline-only environments or restricted networks.

### Dependencies & Tooling

- Upgraded `flutter_rust_bridge` to `2.13.0` across Dart dependencies, Rust crate dependencies, and codegen CLI.
- Added `ureq` v3 (pure Rust TLS with `rustls`) for minimal footprint and cross-platform network requests without OpenSSL dependencies.
- Added `flate2` and `tar` for high-performance `.tar.gz` package decompression.

---

## 2.2.1

### Bug Fixes

- **Android**: Fixed auto-download failing with `Cannot operate on packages inside the cache` — the setup command is now run from the consumer app root instead of the pub cache directory.
- **iOS**: Same root-cause fix — the podspec now runs `dart run typst_flutter:setup` from the app root (`File.expand_path('..', Dir.pwd)`) rather than from inside the pub cache.
- **macOS**: Added auto-download and fallback error — the podspec previously had no binary detection at all and would silently produce a broken build.
- **Linux**: Added auto-download via CMake `execute_process` from the app root, with a clear `FATAL_ERROR` if binaries are still missing.
- **Windows desktop**: Same as Linux, using `cmd /c` for Windows shell compatibility.

---

## 2.2.0

### Engine Upgrade

- **Typst 0.15.0**: Upgraded the underlying Typst compiler engine to [0.15.0](https://typst.app/docs/changelog/0.15.0/). This brings variable font support, improved diagnostics, and many layout refinements. All Typst sub-crates (`typst-pdf`, `typst-render`, `typst-svg`, `typst-layout`, `typst-utils`) are updated in lockstep.

### New Features & Optimizations

- **Shared Compiler Architecture**: Added `TypstCompilerProvider`, an `InheritedWidget` that allows `TypstView` and `TypstDocumentViewer` widgets to seamlessly discover and reuse a globally shared Rust engine instance. This eliminates thread spawning and font decoding overhead, reducing multi-widget rendering latency from ~200ms to **0ms**.
- **Data Extraction**: Added `TypstCompiler.query()` to extract JSON metadata and document structure programmatically using Typst selectors (e.g., `<heading>`).
- **Variable Injection**: Added `sys.inputs` support to `TypstCompiler.compile()`. You can now pass a `Map<String, String>` from Dart directly into the Typst `#sys.inputs` dictionary, safely injecting theme data, usernames, or configuration flags into your documents.
- **Enabled Thin LTO**: Release builds now use `lto = "thin"` for cross-crate link-time optimization, yielding ~5-15% smaller native binaries without major compile-time impact.

---

## 2.1.0

### Optimizations & API Refinements

- **Synchronous Metadata API**: `TypstDocument.pageCount`, `TypstDocument.pageInfo()`, and `TypstCompiler.compilerVersion` are now fully synchronous. By leveraging `flutter_rust_bridge` v2's `#[frb(sync)]` feature, these lightweight calls execute instantly on the main thread, eliminating `Future` overhead and preventing UI layout jumps during rendering.
- **Dynamic Versioning**: The Rust build script now dynamically extracts the exact `typst` crate version from `Cargo.toml`. `compilerVersion` will always be perfectly accurate without manual updates.
- **Robust Date Handling**: The Rust `SimpleWorld` environment now gracefully falls back to the native OS system time (`std::time::SystemTime::now()`) if no date is provided from Dart. This means calling `compile()` without a `date` parameter will no longer crash when evaluating `#datetime.today()` in Typst markup.

### Documentation

- **100% API Hover Docs**: Every public class, method, and field in the Dart API now has extensive documentation comments (`///`), providing a premium developer experience in IDEs.
- **Bundled Fonts Documented**: The built-in core fonts (`Libertinus Serif`, `DejaVu Sans Mono`, and `NewCM Math`) are now explicitly documented in the API so developers know what's available out-of-the-box.

## 2.0.0

### ⚠️ Breaking Changes

- **`TypstDocument` is now an opaque document handle.**
  The old `TypstDocument` (with `.pdf`, `.svgs`, `.imageForPage()`) has been replaced
  with a lightweight handle wrapping the compiled document in Rust memory. Rendering
  and export are now lazy — call `doc.exportPdf()`, `doc.renderSvg(pageIndex)`, or
  `doc.renderRaster(pageIndex: i)` on demand.

- **`compile()` now returns `TypstDocument`** (the opaque handle), not a container
  holding pre-generated PDF bytes. Call `doc.exportPdf()` to get the `Uint8List`.

- **Removed `compileDocument()` / `renderCachedPage()` / `renderCachedPageAsSvg()`.**
  These implicit shared-state APIs are gone. Use `compile()` → `TypstDocument` →
  `renderRaster()` / `renderSvg()` instead. Each `TypstDocument` is independent.

- **Removed `compileSvg()`** — Use `compile()` then `doc.renderSvg(pageIndex)` per page.

- **Removed `renderPage()` / `renderPageAsPng()`** — Use `compile()` then
  `doc.renderRaster()` or call `result.toPng()` for PNG bytes.

- **Removed `TypstSvgView` widget.** Use `TypstView` with
  `renderMode: TypstRenderMode.svg` instead.

- **Removed `PdfDocument`, `SvgDocument`, `RasterDocument`** sealed class hierarchy.
  All compilation now returns `TypstDocument`.

- **`TypstDocumentViewer` replaces `useSvg: bool` with `renderMode: TypstRenderMode`.**

- **`errorBuilder` signature changed from `Object` to `TypstCompileException`.**

### Migration Guide

```dart
// ── Before (1.x) ──────────────────────────────────────────

// PDF
final doc = await compiler.compile(source: markup);
final pdf = doc.pdf; // Uint8List directly

// Raster
final result = await compiler.renderPage(source: markup);
final image = await result.toImage();

// SVG
final doc = await compiler.compileSvg(source: markup);
final svgs = doc.svgs;

// Multi-page (implicit state — race condition prone)
final count = await compiler.compileDocument(source: markup);
final svg = await compiler.renderCachedPageAsSvg(pageIndex: 0);

// ── After (2.0) ───────────────────────────────────────────

// PDF
final doc = await compiler.compile(source: markup);
final pdf = await doc.exportPdf();

// Raster
final doc = await compiler.compile(source: markup);
final result = await doc.renderRaster(pageIndex: 0);
final image = await result.toImage();

// SVG
final doc = await compiler.compile(source: markup);
final svg = await doc.renderSvg(0);

// Multi-page (safe — each doc is independent)
final doc = await compiler.compile(source: markup);
for (var i = 0; i < doc.pageCount; i++) {
  final svg = await doc.renderSvg(i);
}

// Don't forget to dispose when done!
doc.dispose();
```

### New Features

- **`TypstDocument.dispose()`** — Explicit lifecycle management for the native
  Rust document handle. Calling `dispose()` eagerly frees the underlying
  `PagedDocument` memory (which can be several MB). Use-after-dispose throws
  `StateError`. Safe to call multiple times.

- **`TypstDocument.pageInfo(int pageIndex)`** — Query page dimensions in points
  without rendering.

- **`TypstView` dual constructor pattern:**
  - `TypstView(document: doc)` — renders from a pre-compiled document (shared compiler).
  - `TypstView.source(source: markup)` — self-manages compilation (convenience).

- **`TypstDocumentViewer.document()` constructor** — Accepts a pre-compiled
  `TypstDocument`, avoiding per-widget compiler creation.

- **`TypstRenderMode` enum** (`svg`, `raster`) — Replaces the fragile `useSvg: bool`
  flag on `TypstDocumentViewer`.

- **`@internal` annotation on `FontSource.load()`** — Prevents users from calling
  the internal font loading method directly.

### Fixes

- **Fixed image leak in `TypstRenderResult.toPng()`** — The method now creates a
  temporary image and disposes it immediately if no cached image exists, preventing
  native `ui.Image` leaks when `dispose()` is never called.

- **Fixed missing `dispose()` in widget lifecycle** — `TypstView` and
  `TypstDocumentViewer` now properly dispose their owned `TypstCompiler` instances
  in `State.dispose()` and when fonts change in `didUpdateWidget`.

- **Fixed implicit shared mutable state** — `compileDocument()` returned an int and
  stored the document in the Rust engine. Concurrent callers could silently clobber
  each other's documents. The new `TypstDocument` handle eliminates this entirely.

### Internal

- `TypstCompiler._engine` is now private (was `engine` public).
- `TypstCompiler` implements `Finalizable`.
- Typed `TypstCompileException` used throughout (was `Object` in error handlers).
- Added `prefer_expression_function_bodies` lint rule.
- Added `meta` dependency for `@internal` annotation.
- Updated `.pubignore` to exclude internal files from pub.dev.

---

## 1.1.1

- **Feature:** Truly Zero-Configuration native setup! Android and iOS builds now automatically execute `typst_flutter:setup` on the fly to download native binaries. No manual commands required.
- **Fix:** Fixed a severe path-parsing bug on Windows where `setup.dart` crashed with a `PathNotFoundException` while writing macOS binaries.
- **Fix:** Safely fall back to `cargokit` compilation if auto-downloads fail or the user is strictly offline.

## 1.1.0

- **New:** `TypstDocumentViewer` widget for efficiently displaying multi-page documents with lazy rendering.
- **New:** `TypstSvgView` widget for crisp, scalable vector graphics rendering (SVG) at any zoom level. _(Removed in 2.0.0 — use `TypstView` with `TypstRenderMode.svg`)_
- **New:** Structured Error Diagnostics via `TypstCompileException.diagnostics`. Errors now include severity, exact messages, and hints.
- **New:** Date Injection. You can now pass a `DateTime` into the compiler to provide the date for `#datetime.today()`.
- **New:** Support for rendering single pages directly to PNG bytes entirely in Rust (no Flutter UI thread or GPU roundtrip needed) via `renderPageAsPng`.

## 1.0.1

- Fix CI/CD publishing pipeline
- Initial stable release

## 1.0.0

- Initial stable release.
- Added `TypstCompiler` for native PDF compilation.
- Added `TypstView` widget for live preview rendering.
- Support for passing images and custom fonts via virtual files (`FileSource`, `FontSource`).
- Zero-Rust install workflow via `dart run typst_flutter:setup` using pre-built binaries.
- Full cross-platform support: Android, iOS, macOS, Windows, Linux.
