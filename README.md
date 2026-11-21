# typst_flutter

[![CI](https://github.com/ajmalbuv/typst_flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/ajmalbuv/typst_flutter/actions/workflows/ci.yml)
[![Pub Version](https://img.shields.io/pub/v/typst_flutter)](https://pub.dev/packages/typst_flutter)
[![Documentation](https://img.shields.io/badge/docs-pub.dev-blue)](https://pub.dev/documentation/typst_flutter/latest/)
[![Pub Points](https://img.shields.io/pub/points/typst_flutter)](https://pub.dev/packages/typst_flutter)
[![codecov](https://codecov.io/gh/ajmalbuv/typst_flutter/graph/badge.svg)](https://codecov.io/gh/ajmalbuv/typst_flutter)
[![style: very good analysis](https://img.shields.io/badge/style-very_good_analysis-B22C89.svg)](https://pub.dev/packages/very_good_analysis)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Embed the **Typst typesetting compiler** into your Flutter apps: native Rust via
FFI on Android, iOS, macOS, Windows and Linux, and WebAssembly in the browser.

Compile Typst markup to high-quality PDF documents or rendered images on-device.
No WebView, no server, no network round-trip.

## Links

- **Documentation:** [pub.dev/documentation/typst_flutter](https://pub.dev/documentation/typst_flutter/latest/)
- **GitHub:** [github.com/ajmalbuv/typst_flutter](https://github.com/ajmalbuv/typst_flutter)
- **Pub.dev:** [pub.dev/packages/typst_flutter](https://pub.dev/packages/typst_flutter)

## Features

- **Native Performance:** Typst runs directly on the device using a Rust core, compiling most documents in under 100ms.
- **Opaque Handle Architecture:** Compiled documents live in Rust memory, ensuring high performance and zero race conditions.
- **Shared Compiler Architecture:** Use `TypstCompilerProvider` to reuse a single engine globally across your widget tree for 0ms overhead rendering.
- **Data Extraction:** Native `query()` API to extract JSON metadata and document structure using Typst selectors.
- **Widgets Included:** Drop-in `TypstDocumentViewer` and `TypstView` widgets for instant live previews with Raster or SVG support.
- **Structured Error Handling:** Get detailed `TypstDiagnostic` error lines when Typst compilation fails, perfect for building in-app editors.
- **Virtual File System & Inputs:** Pass Flutter assets, raw memory bytes, and `sys.inputs` dictionaries directly into the Typst compiler.
- **Typst Package Registry:** Full support for `#import "@preview/..."` with automatic downloading, decompression, and in-memory caching — fetched in Rust on native platforms and in Dart (before compiling) on the web.
- **Web Support:** The same API runs in the browser from WebAssembly, including the `TypstView` and `TypstDocumentViewer` widgets, PDF export, raster and SVG rendering, and `@preview` packages. See the [web guide](docs/src/content/docs/guides/web.md) for what differs.

## Getting started

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  typst_flutter: 3.2.0
```

Then fetch dependencies and run the **required** one-time setup:

```bash
flutter pub get
dart run typst_flutter:setup
```

> **Why is this required?**
> `typst_flutter` ships a native Rust library (~15MB per ABI). Because pub.dev has a 100MB size limit, the pre-built binaries live on GitHub Releases. The setup script downloads the correct binaries for your platform and places them where the Flutter build system expects them.
>
> Re-run it after `flutter pub get`, `flutter pub upgrade`, `pub cache clean`
> or `pub cache repair`, and after changing a git dependency's ref: the
> libraries live inside the package, which for a git dependency means inside
> the pub cache, and a new ref resolves to a new pub-cache directory.

> **Tip:** Gradle (Android) and CMake (Linux/Windows) still run
> `dart run typst_flutter:setup` automatically at build time when their
> libraries are missing. iOS and macOS never do: if the Apple libraries are
> gone, the Swift package fails to resolve instead of compiling anything, so
> run setup first.

> **iOS / macOS:** since 3.2.0 both platforms are integrated with Swift Package
> Manager (Flutter 3.44+). The libraries are installed into
> `ios/typst_flutter/Binaries/` and `macos/typst_flutter/Binaries/`, and the
> package links the Rust archive into the app binary (no dylib, no framework,
> nothing to embed). CocoaPods is not used at all.

> **Android:** the libraries are linked for 16 KB memory pages, which Android 15
> and later can use and Play requires of every 64-bit native library. There is
> nothing to configure in the app; a fork that builds its own libraries gets the
> same linker flags from `rust/build.rs`.

### Working on a fork or a local checkout

`setup` installs from GitHub Releases by default. To use libraries you built
yourself instead — no release, no network:

```bash
dart run typst_flutter:setup --local          # the checkout's own build output
dart run typst_flutter:setup --from ./dist    # a directory of artifacts
```

`--local` reads `rust/target/release` (host), `rust/target/<triple>/release`
(Android ABIs) and `example/web/pkg` (web) from the package checkout, so
`just build-host` / `just build-android` / `just build-web` are enough. On
macOS, `--local` also wraps the host library into the xcframework SwiftPM
needs; `just build-ios-local` builds the iOS xcframework from source. Add
`--web` to install the wasm bundle into your app, or pass `--from <dir>` with
release-shaped files (`libtypst_flutter_macos.a`, `typst_flutter_web.tar.gz`,
…). Nothing is downloaded and no checksum applies: what you built is what gets
installed.

When the package is a fork, `setup` also takes release assets from the
repository named in the package's `pubspec.yaml` `repository:` field, so point
that at your fork (or pass `--repo owner/name`).

### Web

Building for the browser needs one extra step, which fetches the WebAssembly
bundle into your app's `web/pkg` directory:

```bash
dart run typst_flutter:setup --web
```

The page must then be served cross-origin isolated, or the wasm cannot use
worker threads:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

For development:

```bash
flutter run -d chrome --wasm \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

```dart
import 'package:typst_flutter/typst_flutter.dart';

final compiler = await TypstCompiler.create();
final doc = await compiler.compile(source: '= Hello from the browser');
// TypstView and TypstDocumentViewer work unchanged.
```

Host-specific header snippets, the 1 GiB wasm memory ceiling and the other
web differences are covered in the [web guide](docs/src/content/docs/guides/web.md).

## Usage

### Rendering a PDF

Use `TypstCompiler.create()` to initialize the engine and build documents:

```dart
import 'package:typst_flutter/typst_flutter.dart';

final compiler = await TypstCompiler.create();

// Compile to an opaque document handle
final doc = await compiler.compile(
  source: r'''
    #set page(width: 148mm, height: 210mm, margin: 1cm)
    = Hello Typst!

    This is rendered *natively* in Flutter.
    #sys.inputs.at("theme", default: "light")
  ''',
  inputs: {'theme': 'dark'}, // Safely pass variables to Typst
);

// Query metadata/structure from the compiled document
final headingJson = await compiler.query(document: doc, selector: '<heading>');

// Export to PDF bytes
final pdfBytes = await doc.exportPdf();

print('Generated a ${doc.pageCount}-page PDF (${pdfBytes.length} bytes).');
// You can now save pdfBytes to disk or share it!

// Don't forget to dispose the document handle
doc.dispose();
```

### Live Preview Widget

The `TypstDocumentViewer` widget automatically compiles and renders your document, providing a scrollable, zoomable UI.

```dart
import 'package:flutter/material.dart';
import 'package:typst_flutter/typst_flutter.dart';

class MyEditor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return TypstDocumentViewer(
      source: r'''
        = Multi-page Viewer
        This document spans multiple pages.
        #pagebreak()
        And scrolling is instantly fast because the document handle is immutable!
      ''',
      renderMode: TypstRenderMode.svg, // Use SVG for crisp vector text
    );
  }
}
```

### Shared Compiler Performance (Best Practice)

To avoid spawning a new Rust thread for every widget, wrap your app or page in a `TypstCompilerProvider`. Any `TypstView` or `TypstDocumentViewer` underneath will automatically discover and reuse the shared compiler instantly!

```dart
// 1. Initialize once
final compiler = await TypstCompiler.create();

// 2. Wrap your app
TypstCompilerProvider(
  compiler: compiler,
  child: Scaffold(
    body: ListView(
      children: [
        // 3. These render instantly using the shared engine!
        TypstView.source(source: '$ x^2 + y^2 = r^2 $'),
        TypstView.source(source: '$ e^(i pi) + 1 = 0 $'),
      ],
    )
  )
)
```

## Building the native library yourself

There is no compile-from-source fallback inside the Flutter build any more
(Cargokit and the `rust_builder` package are gone). If you are offline, on a
custom architecture, or hacking on the Rust side, build the artifacts and
install them yourself:

```bash
just build-host         # host library + macOS xcframework, then setup --local
just build-ios-local    # iOS xcframework (device arm64 + simulator fat)
just build-android      # Android ABIs
dart run typst_flutter:setup --local
```

This needs a Rust toolchain (`rustup`) and Xcode; the first build takes several
minutes because Typst is compiled with fat LTO.

## Testing

Because this package relies on native Rust libraries via FFI, unit tests must be run as integration tests against a host platform.

```bash
flutter test integration_test/simple_test.dart
```

## Author

Ajmal ([@ajmalbuv](https://github.com/ajmalbuv))
