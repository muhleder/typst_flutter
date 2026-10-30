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

> Working inside this repository instead? `just build-web` builds the bundle
> into `example/web/pkg` from source.

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
- **There is no filesystem.** Pass images, data files and includes with
  `FileSource.bytes` (or `FileSource.assets`) rather than reading from disk.
- **Custom registries**: point the prefetcher somewhere else with
  `TypstFlutter.configure(packageRegistryUrl: 'https://typst.example.com')`.
- **A custom bundle location** (a CDN, or a sub-path deployment) is a codegen
  setting: regenerate with `default_external_library_loader_web_prefix` set to
  the prefix you serve the bundle from. By default it is `pkg/`, resolved
  relative to the page, so a sub-path deployment works without changes.

## Known limitation: one call at a time per handle

`#[frb(sync)]` calls on the web run on the browser's event loop and fail
immediately if an asynchronous call still holds the same object. In practice
that means: always `await` a call before starting the next one on the same
compiler or document. The bundled widgets already do this.
