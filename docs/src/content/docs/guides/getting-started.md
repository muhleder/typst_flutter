---
title: Getting Started
description: How to install and start using typst_flutter
---

`typst_flutter` is the easiest way to bring professional typesetting to your Flutter apps. Because it utilizes prebuilt Rust binaries, you don't even need a Rust toolchain to get started.

## Installation

Add the package to your Flutter project's `pubspec.yaml`:

```bash
flutter pub add typst_flutter
```

## Setup (required once)

After adding the package, run the setup script from your **app root**:

```bash
flutter pub get
dart run typst_flutter:setup
```

This downloads the prebuilt native Typst libraries (~15MB) from GitHub Releases
and installs them inside the package — no Rust toolchain required. Re-run it
after `flutter pub get`, `flutter pub upgrade`, `pub cache clean`/`repair`, and
after changing a git dependency's ref: a new ref resolves to a new pub-cache
directory, and the libraries live inside the package.

On iOS and macOS the libraries are installed as xcframeworks inside
`ios/typst_flutter/Binaries/` and `macos/typst_flutter/Binaries/`, which is what
the Swift packages link.

> **Why is this step needed?**
> pub.dev has a 100MB package size limit. The native `.so`/`.dll`/`.a` binaries
> live on GitHub Releases instead, and this script fetches the right one for your
> platform automatically.

### Build-time auto-download

Gradle (Android) and CMake (Linux/Windows) still run
`dart run typst_flutter:setup` automatically when their libraries are missing.
iOS and macOS do not: if the libraries are absent, the Swift package fails to
resolve and SwiftPM reports the missing binary target, so run:

```bash
dart run typst_flutter:setup
```

## Default Built-in Fonts

By default, the compiler is lightweight but comes bundled with the following core fonts to ensure your basic documents and math formulas render perfectly out of the box:

- **Libertinus Serif** (Regular) - The default serif font for Typst.
- **DejaVu Sans Mono** - The default monospaced font for code blocks.
- **NewCM Math** (Book) - The default font for rendering complex mathematical formulas.

If you need additional fonts (e.g., custom brand fonts or emoji fonts), you can pass them via the `FontSource` API when calling `TypstCompiler.create()`.

## Basic Usage (PDF Generation)

Use `TypstCompiler.create()` to initialize the engine, and pass your Typst source code to compile a high-quality PDF:

```dart
import 'package:typst_flutter/typst_flutter.dart';

// 1. Initialize the compiler (loads the native binaries)
final compiler = await TypstCompiler.create();

// 2. Compile your source code to an opaque handle
final doc = await compiler.compile(
  source: r'''
    #set page(width: 148mm, height: 210mm, margin: 1cm)

    = Hello Typst!

    This is rendered *natively* in Flutter.
  ''',
);

// 3. Export to PDF bytes
final pdfBytes = await doc.exportPdf();

print('Generated a ${doc.pageCount}-page PDF (${pdfBytes.length} bytes).');

// Don't forget to dispose the document when you're done!
doc.dispose();
```

You can then pass `pdfBytes` to packages like `printing` or save it to the device's file system using `path_provider`.

## Live Preview Widget

If you want to display Typst documents directly in your UI (like a real-time editor), use the `TypstDocumentViewer` widget. It automatically manages the compilation lifecycle.

```dart
import 'package:flutter/material.dart';
import 'package:typst_flutter/typst_flutter.dart';

class TypstPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return TypstDocumentViewer(
      source: r'''
        = Multi-page Viewer
        This document spans multiple pages.
        #pagebreak()
        And scrolling is instantly fast because the document handle is immutable!
      ''',
      renderMode: TypstRenderMode.svg, // Use SVG for crisp vector rendering
    );
  }
}
```

## Advanced: Building from source

There is no compile-from-source fallback inside the Flutter build (Cargokit and
the `rust_builder` package were removed in 3.2.0). To build the native library
yourself — offline, on a custom architecture, or while hacking on the Rust side:

```bash
just build-host         # host library + macOS xcframework
just build-ios-local    # iOS xcframework (device arm64 + simulator fat)
just build-android      # Android ABIs
dart run typst_flutter:setup --local
```

This needs [Rust](https://rustup.rs/) and, for iOS/macOS, Xcode. First-time
compilation takes several minutes because Typst is built with fat LTO.
