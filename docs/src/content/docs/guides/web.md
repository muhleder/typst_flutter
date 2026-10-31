---
title: Web (WebAssembly)
description: Compile and preview Typst documents in a Flutter app that runs in the browser
---

`typst_flutter` runs on the web through WebAssembly. The Dart API is the same
as on native platforms: `TypstCompiler`, `TypstDocument`, `TypstView` and
`TypstDocumentViewer` all work unchanged.

## Setup

The browser build loads a WebAssembly bundle from your app's `web/` directory.
Fetch it once per version upgrade, from your app root:

```bash
dart run typst_flutter:setup --web
```

This downloads `typst_flutter_web.tar.gz` from the matching GitHub release,
verifies it against `SHA256SUMS`, and unpacks `pkg/typst_flutter.js` and
`pkg/typst_flutter_bg.wasm` into `web/pkg`.

> Working inside this repository, or on a fork, instead? `just build-web` builds
> the bundle into `example/web/pkg` from source and

```
dart run typst_flutter:setup --local --web
```

> installs it into your app's `web/pkg` without touching the network. `--from
> <dir>` does the same from any directory containing `pkg/` or a
> `typst_flutter_web.tar.gz`.

## Required response headers

The wasm uses worker threads, so the page must be **cross-origin isolated**.
Serve these two headers with every response of the app:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without them the module still loads, but the compiler cannot use worker
threads and package downloads may be blocked; `typst_flutter` logs a warning
to the console in that case.

### Development

```bash
flutter run -d chrome --wasm \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

Drop `--wasm` to run the JavaScript build; the wasm bundle is used either way.

### Hosting

**nginx**

```nginx
add_header Cross-Origin-Opener-Policy same-origin always;
add_header Cross-Origin-Embedder-Policy require-corp always;
```

**Firebase Hosting** (`firebase.json`)

```json
{
  "hosting": {
    "headers": [
      {
        "source": "**",
        "headers": [
          { "key": "Cross-Origin-Opener-Policy", "value": "same-origin" },
          { "key": "Cross-Origin-Embedder-Policy", "value": "require-corp" }
        ]
      }
    ]
  }
}
```

**Netlify / Cloudflare Pages** (`_headers`)

```
/*
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
```

**Vercel** (`vercel.json`)

```json
{
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "Cross-Origin-Opener-Policy", "value": "same-origin" },
        { "key": "Cross-Origin-Embedder-Policy", "value": "require-corp" }
      ]
    }
  ]
}
```

**GitHub Pages** cannot set response headers, so a Flutter web app using
`typst_flutter` cannot be hosted there directly. Put a proxy that sets the
headers in front of it.

## What is different on the web

- **Packages are fetched before compiling.** A browser cannot make a network
  request from inside Typst's synchronous file lookup (`World::file`), so
  `compile()` downloads every `@preview/...` package it finds — including
  transitive ones — and injects them into the compiler before compiling. The
  cache belongs to the compiler instance, so recompiling for live preview
  does not download anything twice.
- **Memory is capped at 1 GiB per instance.** That is ample for typical
  documents and is the usual reason a very large document fails on the web.
- **Typst's layout runs single-threaded** inside one worker thread. The
  compile itself never blocks the UI thread, but a document does not
  parallelise internally the way it does on a desktop.
- **PDF export runs on the calling thread.** `typst_pdf` -> `krilla` hands its
  per-page streams, font subsets and images to `rayon::spawn` and blocks on the
  result, and a browser cannot spawn rayon workers: rayon's wasm fallback pool is
  one worker, owned by whichever thread first touched rayon. A `spawn` from any
  other thread is queued where nothing runs it, so the export used to block for
  ever. It now runs inside a pool the calling thread owns, which makes the export
  synchronous and single-threaded - it does not block the UI thread (that work is
  already on a Web Worker), but it does not parallelise either.
- **There is no filesystem.** Pass images, data files and includes with
  `FileSource.bytes` (or `FileSource.assets`) rather than reading from disk.
- **Custom registries**: point the prefetcher somewhere else with
  `TypstFlutter.configure(packageRegistryUrl: 'https://typst.example.com')`.
- **A custom bundle location** (a CDN, or a sub-path deployment) is a codegen
  setting: regenerate with `default_external_library_loader_web_prefix` set to
  the prefix you serve the bundle from. By default it is `pkg/`, resolved
  relative to the page, so a sub-path deployment works without changes.

## One call at a time

Every asynchronous call this package makes into Rust goes through a single
queue - `compile`, `addFonts`, `query`, `renderRaster`, `renderSvg` and
`exportPdf`, across every compiler and every document. You never see it, but it
is why a preview can compile a chapter while a page is still being rendered:
concurrent calls do not wait for each other in a browser, they fail.

The reason is in the wasm build rather than in this package. Typst's
memoization cache (`comemo`) is process-wide and behind `parking_lot` locks,
and `parking_lot`'s wasm parker panics with `Parking not supported on this
platform` instead of blocking. Two calls that overlap therefore take the wasm
instance down with an `unreachable` trap, and the call that traps fails
quietly - a page that stops updating, with nothing in the console to say why.
The queue costs a pass in a straight line and removes the failure entirely.

What it does not cover is `#[frb(sync)]` calls - `pageCount`, `pageInfo`,
`warnings`, `dispose` - which run on the browser's event loop and fail
immediately if an asynchronous call is holding the same object. Reading a
document's page count while it is being rendered is still the caller's to
sequence, which is why the bundled widgets `await` before they read.
