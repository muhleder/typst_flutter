# Flutter Web (WASM) support — design

- **Date:** 2026-10-30
- **Status:** awaiting approval
- **Supersedes:** `todo.md` → P4 "Flutter Web Support (WASM)"
- **Target version:** `typst_flutter` 3.1.0

## 1. Intent

`typst_flutter` today embeds the Typst compiler through `dart:ffi` and explicitly
does not support web (`pubspec.yaml`, `README.md`, `GEMINI.md` all say so). We are
adding web as a first-class platform: a Flutter app compiled to WebAssembly
(`flutter build web --wasm`) must be able to compile Typst markup, render/preview
documents with the existing widgets (`TypstView`, `TypstDocumentViewer`), export
PDF/SVG, and use `#import "@preview/..."` packages — with the same Dart API it
uses on native platforms.

The user's framing: **web as a genuinely supported platform**, used to compile
documents and preview them in-app — not a demo.

## 2. Goals

1. `TypstCompiler.create()` / `compile()` / `TypstDocument` render + export work in
   a browser, with no API changes for callers.
2. `TypstView` / `TypstDocumentViewer` work on web in both `svg` and `raster` modes.
3. `@preview/...` package imports work on web, downloaded over `fetch`.
4. Compiling never blocks the browser main thread (no frozen UI).
5. Web is **built and tested in CI** and shipped as a release artifact, with a
   documented setup path a consumer can follow without reading this repo.
6. The existing native platforms keep their current behaviour and performance.

## 3. Non-goals

- Node.js / Deno / `wasm32-wasip1` support.
- Dart-side `Isolate`/`compute` parallelism; going below one FRB worker for Typst.
- Persistent disk package cache on web (`todo.md` P2 desktop work), font subsetting,
  or host font discovery.
- Offline-first package caching in the browser.
- A separate "web-only" public API. Web is a platform switch, not a fork.

## 4. Anti-goals (would count as failure even if it "works")

- Requiring consumers to edit generated `frb_generated*.dart` files.
- Web shipping as an untested side path: if CI does not build and exercise it, it rots.
- Silently degrading: a missing/absent wasm bundle must produce an actionable error,
  never a blank screen or a hung `await`.
- Changing native threading semantics to make web easier (see Approaches, option A).

## 5. Verified constraints (these drove the design)

| Fact | Consequence |
|---|---|
| `World::file()` is synchronous (`rust/src/world/mod.rs`), and browser `fetch` is async | Packages cannot be downloaded *during* compilation. They must be fetched before `compile()` and injected into the resolver cache. |
| FRB dispatches non-`#[frb(sync)]` Rust calls via `SimpleExecutor::execute_normal` → thread pool. On web that pool is a **wasm worker pool** (`frb_rust/src/thread_pool/web.rs` → `wasm_bindgen` worker pool) | Compile/render/pdf already run off the main thread once the threaded wasm build is used — no extra worker plumbing needed. |
| Threaded wasm uses shared memory (`build-web` default rustflags: `+atomics`, `--shared-memory`, `--import-memory`, `--max-memory=1073741824`) | The host must send `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`), otherwise `WebAssembly.Memory could not be cloned` / no shared buffers. Also: the wasm instance is capped at **1 GiB**. |
| `rayon` is a hard dependency of `typst-library`, `typst-utils` and (optionally) `krilla`/`typst-pdf`; rayon-core ≥1.7 has a documented **global fallback when threading is unsupported** (`wasm32-unknown-unknown` returns `Unsupported` → single-threaded pool) | No rayon workaround needed. Layout/render/PDF run serially inside the FRB worker on web. Typst itself already accounts for this (`typst-utils/src/deferred.rs` comment: "for WASM compatibility"). |
| `std::thread::spawn` is unimplemented on `wasm32-unknown-unknown`; `SystemTime::now()` is not available | `world::today()` must not call `SystemTime::now()` on wasm; nothing else in our crate spawns threads (only `package/mod.rs` tests do). |
| `packages.typst.org` returns `access-control-allow-origin: *` and `cross-origin-resource-policy: cross-origin` (verified 2026-10-30) | Dart-side `fetch` of package tarballs works, including under COEP `require-corp`. |
| FRB gained Dart-Wasm (`--wasm`) support in **2.14.0-beta.2** (`Support Dart Wasm output in build-web` #3431, `Document Dart WebAssembly support` #3437); this repo pins 2.13.0 | The bridge must be upgraded to `2.14.0-beta.2` (exact pin). Beta dependency is an accepted risk, recorded in §11. |
| FRB's `initializeWasmModule` injects `<script src="$root.js">` and awaits `onLoad` only | A 404 hangs forever with no diagnostic. We ship our own ~40-line loader that also handles `onerror` (see §7.3). |
| `build-web` writes `<output>/pkg/<crate>.js` + `<output>/pkg/<crate>_bg.wasm`; generated default `webPrefix` is `pkg/` | Serving the artifacts from the host app's `web/pkg/` requires **no codegen config change**. |
| Flutter serves package assets from `/assets/packages/<pkg>/...`, and `dart pub publish` cannot ship files that are git-ignored | Shipping the wasm as a bundled plugin asset would force a committed ~10 MB binary. Rejected — see §6, option 3. |
| `lib/` contains no `dart:io`; widgets are pure `dart:ui` + `flutter_svg`; `ui.ImmutableBuffer`/`ImageDescriptor` exist on web | The preview widgets need no changes for web (verify, don't rewrite). |
| **`lib/src/compiler.dart:1` imports `dart:ffi` only to declare `implements Finalizable`** | A hard build blocker on web. The import and the `Finalizable` supertype must go; `dispose()` stays and remains the documented lifecycle call. Micro-breaking for anyone who typed the compiler as `Finalizable` — CHANGELOG note. The CI platform rule must forbid **`dart:ffi` and `dart:io`** in `lib/`, not just `dart:io`. |
| FRB's opaque handles are `RustAutoOpaque` ids backed by shared memory; `#[frb(sync)]` calls execute on the browser event loop and **fail immediately** if an async call still holds a borrow of the same handle (`wasm-limitations`) | Handles are shared, not copied, so the engine's fonts/caches are not re-sent per call. But sync and async calls on the *same* handle must never overlap: every new call site awaits the previous one. This rule is exercised by the browser probe (plan Task 4) and documented for users (plan Task 11). |

## 6. Approaches considered

**A. Zero-config, single-threaded (`default_dart_async: false`), assets bundled in the package.**
No COOP/COEP headers, no setup step. Rejected: (i) `default_dart_async` is crate-wide, so
every currently-async Rust fn becomes a main-thread sync call — it changes native dispatch
semantics for existing users, which is exactly the accepted-risk-free behaviour we promised
not to touch; (ii) with sync calls, a Typst compile freezes the browser tab, and a document
preview app that freezes on every recompile is not "supported"; (iii) bundling the wasm as a
Flutter asset forces a large binary into git or into the pub package (100 MB limit, and
`dart pub publish` ignores git-ignored files).

**B. Threaded build + worker pool + host-provided COOP/COEP (chosen).**
FRB's wasm worker pool runs `compile`/`render`/`export*` off the main thread; native async
semantics are untouched; no codegen config changes. Cost: the consumer's server must send two
headers (one-time, documented), and wasm is capped at 1 GiB.

**C. Ship A's artifact as default and B's as optional, choose at runtime via `crossOriginIsolated`.**
Rejected for now: two wasm artifacts (~2× size), two build paths in CI, and the fallback path is
the one no user exercises. Revisit only if header configuration proves to be a real adoption
blocker.

**Package downloads — Dart prefetch chosen over Rust `fetch`.** The alternative (branch `ureq`
to `web-sys` inside an async Rust prefetch) keeps the logic in Rust but adds wasm-only FFI
dependencies and async plumbing to a module that is currently trivially testable, and still
needs a "prefetch before compile" API because of the synchronous `World::file()`. Prefetching in
Dart reuses `package:http` (already a dependency) and the same tar-unpacking code the native path
uses, and it is the foundation for the P2 persistent cache.

**Artifact distribution — download-at-setup chosen over bundled assets.** The project already
distributes native binaries this way (`bin/setup.dart`, `SHA256SUMS` on the GitHub release,
`.typst_flutter_prebuilt/`). Web follows the same model: release asset `typst_flutter_web.tar.gz`
containing `pkg/typst_flutter.js` + `pkg/typst_flutter_bg.wasm`, verified against `SHA256SUMS`,
unpacked into the **consuming app's** `web/pkg/`. No huge binaries in git or on pub.dev, and the
setup command already exists in every consumer's workflow.

## 7. The design

### 7.0 Order of work (de-risk before freezing the API)

1. **Spike A — toolchain + typst on wasm.** Install nightly + `rust-src` +
   `wasm32-unknown-unknown` + `wasm-pack`; `flutter_rust_bridge_codegen build-web --release` the
   crate as it stands today. Confirm `typst`/`typst-pdf`/`typst-render`/`typst-svg` compile, and
   record the artifact size. Output: a wasm blob, not a feature.
2. **Spike B — FRB opaque + sync/async interop in a real browser.** With the FRB bump in place,
   drive `TypstEngine` from a throwaway page: create (sync) → compile (async) → `page_info`
   (sync) → `render_raster` (async) → PDF, plus a deliberate sync call issued *while* an async
   call is in flight, to confirm the failure mode matches §5 rather than deadlocking. This fixes
   the API surface in §7.2 before anything else is written around it.
3. Only then: the public API, prefetcher, loader, setup/release plumbing, docs.

If Spike A or B fails, stop and re-open the approach question (§6) instead of working around it.

### 7.1 Bridge upgrade

- `pubspec.yaml`: `flutter_rust_bridge: 2.14.0-beta.2` (exact, no caret — pub cannot resolve a
  range across the prerelease boundary meaningfully), keep `archive`, `http`, etc. unchanged.
- `rust/Cargo.toml`: `flutter_rust_bridge = "=2.14.0-beta.2"`.
- Regenerate (`just gen`) with `flutter_rust_bridge_codegen` 2.14.0-beta.2. Commit the regenerated
  `lib/src/rust/**` and `rust/src/frb_generated.rs`. `flutter_rust_bridge.yaml` keeps
  `webPrefix: 'pkg/'` (default) — no config change.
- Verify native behaviour is unchanged (the 2.13→2.14 diff is web-focused, but the native test
  suite must stay green before anything else lands).

### 7.2 Rust changes

`rust/Cargo.toml`

- Move `ureq` into `[target.'cfg(not(target_family = "wasm"))'.dependencies]`.
- Add `[target.'cfg(target_family = "wasm")'.dependencies] js-sys = "0.3"` (for `Date::now()`).
- Keep `panic = "abort"`; `build-web` passes `-Z build-std=std,panic_abort`.

`rust/src/package/mod.rs`

- New error variant `PackageError::NotPrefetched { spec }` whose message tells the caller a web
  build cannot download packages during compilation and that `TypstCompiler` must prefetch.
- `ensure_package`: the network branch is `#[cfg(not(target_family = "wasm"))]`; on wasm, an
  uncached spec returns `NotPrefetched`. Cached lookups, `resolve_package_file`, and
  `unpack_package_archive` are unchanged and shared by both paths.
- Add `pub(crate) fn insert_package_archive(&self, spec: &PackageSpec, bytes: &[u8]) -> Result<Vec<PackageSpec>, FileError>`:
  unpack with the existing `unpack_package_archive`, insert into `cache`, then scan the new `.typ`
  entries with the existing `collect_package_specs` and return the specs it has not seen yet
  (transitive deps for the Dart side to fetch next).
- Keep `pre_resolve_packages` for native; on wasm it is `#[cfg]`-excluded from the compile path so
  it can never attempt a network call.

`rust/src/world/mod.rs`

- `today()`: wasm branch uses `js_sys::Date::now() / 1000.0`; native keeps `SystemTime::now()`.

`rust/src/api/typst.rs` (new public bridge surface, additive)

```rust
/// One registry archive to inject (already downloaded by the caller).
pub struct PackageArchive { pub spec: String, pub bytes: Vec<u8> }

impl TypstEngine {
    /// `@preview/name:1.2.3` specs referenced by the markup and the given .typ files.
    #[frb(sync)]
    pub fn scan_package_specs(&self, markup: &str, files: Vec<VirtualFile>) -> Vec<String>;

    /// Specs already resident in this engine's resolver cache.
    #[frb(sync)]
    pub fn cached_package_specs(&self) -> Vec<String>;

    /// Inject downloaded archives; returns still-unresolved (transitive) specs.
    pub fn add_package_archives(&mut self, archives: Vec<PackageArchive>)
        -> Result<Vec<String>, String>;
}
```

`scan_package_specs` / `cached_package_specs` are `#[frb(sync)]` deliberately: both are pure
metadata reads (string scanning, cache keys), a few hundred microseconds on the event loop.
Everything expensive stays async and therefore on the worker pool. The two sync calls take
`&self`, the async one `&mut self`; the prefetcher awaits each call before issuing the next, so no
borrow ever overlaps (see the constraint row in §5).

**Cache ownership:** the engine's resolver cache is the single source of truth, exactly as on
native. `TypstCompiler` keeps no Dart-side package state, so a recompile triggered by a keystroke
issues zero network requests once a package is cached — the prefetcher filters `scan_package_specs`
against `cached_package_specs` before fetching.

No change to `compile`, `render_raster`, `export_svg`, `export_pdf`, `query`, `page_info`.

### 7.3 Dart changes

New files:

- `lib/src/web/loader.dart` + `loader_web.dart` / `loader_stub.dart` (conditional import).
  Mirrors FRB's loader but with real failure handling: append `<script src="$root.js">` to the
  document head, complete on `load`, throw `TypstWebSetupException` on `error` (with the exact
  setup command and the COOP/COEP snippet), warn once via `console` when
  `crossOriginIsolated` is false, then call the global `wasm_bindgen('$root_bg.wasm')` and hand
  FRB an `ExternalLibrary(wasmBindgenName: 'wasm_bindgen')`.
  `root` defaults to `pkg/typst_flutter`.
- `lib/src/packages.dart`: `PackagePrefetcher`. Given markup + `FileSource` bytes + an optional
  `http.Client`, it loops: scan specs (sync Rust) → for each spec not already downloaded,
  `GET $registry/{namespace}/{name}-{version}.tar.gz` → `addPackageArchives` → feed the returned
  transitive specs back into the queue. Guarded by a visited set and a max-rounds limit so a
  pathological package cycle cannot spin forever. Errors surface as a `TypstCompileException`
  diagnostic naming the spec and URL.
- `lib/src/exceptions.dart`: add `TypstWebSetupException extends TypstException`.

Changed files:

- `lib/src/compiler.dart`:
  - Delete `import 'dart:ffi'` and `implements Finalizable` (§5); `dispose()` is unchanged.
  - `TypstCompiler.create({FontSource? fonts, String? webModuleRoot, String? packageRegistryUrl, http.Client? httpClient})`
    — all new parameters optional; on native they are ignored (documented). Unset values fall back
    to the process-wide defaults from `TypstFlutter.configure`.
  - On web, `create` installs the loader before `RustLib.init()`, and wraps init failures:
    a stale `web/pkg` bundle (FRB's content-hash/codegen-version mismatch) or a failed script load
    both surface as `TypstWebSetupException` naming the re-run command, never a hung `await`.
  - `compile()`: when `allowPackages` and running on web, run `PackagePrefetcher` before calling
    the engine. Native path untouched (Rust still downloads).
- `lib/src/config.dart` (new): `TypstFlutter.configure({webModuleRoot, packageRegistryUrl})` —
  process-wide defaults, so the self-managing widgets (`TypstView.source`,
  `TypstDocumentViewer(source:)`, `TypstCompilerProvider`) pick up CDN/sub-path hosting without
  new widget parameters. Widget constructors stay unchanged (keeps goal 1 honest).
- `lib/typst_flutter.dart`: export `TypstWebSetupException` and `TypstFlutter`; prefetcher stays internal.

Cross-platform detection uses `kIsWeb` from `package:flutter/foundation.dart` — no `dart:io`
usage is introduced anywhere in `lib/`.

### 7.4 Artifacts, setup and hosting

- `just build-web` (new recipe): `flutter_rust_bridge_codegen build-web --release -o example/web`
  → `example/web/pkg/typst_flutter.js` + `typst_flutter_bg.wasm`.
- `bin/setup.dart`: new **`--web`** mode. It is opt-in, never part of a bare `dart run
  typst_flutter:setup`: native-only consumers must not receive ~10 MB of web files they did not
  ask for. It downloads `typst_flutter_web.tar.gz` for the running package version from the GitHub
  release, verifies it against `SHA256SUMS`, and unpacks `pkg/` into the **current working
  directory's** `web/` folder. Its own version stamp lives next to the artifacts
  (`web/pkg/.typst_flutter_web_version`) because the existing `.typst_flutter_prebuilt/.version`
  lives in the package root and marks native state; the web stamp is per-app. Idempotent, and it
  prints the headers the app must serve plus the `flutter run` invocation.
- Docs (`README.md`, `docs/src/content/docs/guides/web.md`) cover: setup, the two required
  response headers with copy-paste snippets for nginx, Firebase Hosting, Netlify, Cloudflare
  Pages and Vercel (and an explicit note that GitHub Pages cannot set them), the dev-server
  invocation (`flutter run -d chrome --wasm --web-header=Cross-Origin-Opener-Policy=same-origin
  --web-header=Cross-Origin-Embedder-Policy=require-corp`), the 1 GiB wasm memory ceiling, and the
  fact that Typst layout runs single-threaded inside one worker on web.
- `example/web/` scaffold added (`index.html` + manifest) so the example can be run in a browser;
  `example/justfile` gains `run-web` / `build-web` recipes using the header flags.
- `pubspec.yaml` declares web as a plugin platform (`flutter.plugin.platforms.web` with a small
  `dartPluginClass` registrar that does nothing beyond existing). This is what makes pub.dev label
  the package web-capable and what Flutter's plugin tooling reads — a product claim, not a
  mechanism (the wasm is loaded by our own loader, not by plugin registration).
- Copy fixes: `pubspec.yaml` description (drop "except web", "no WASM"), `README.md` first
  paragraph and Features list, `GEMINI.md` comparison table (it currently claims web is
  unsupported and "no WASM"), `todo.md` P4 item ticked with a note, `CHANGELOG.md` entry.

### 7.5 CI and release

`ci.yml`

- `web-build` (ubuntu): `dtolnay/rust-toolchain@nightly` + `rust-src` + `wasm32-unknown-unknown`
  + `wasm-pack`; `dart run flutter_rust_bridge:build-web --release -o example/web`; then
  `flutter build web --wasm` on the example. Fails if the wasm exceeds the size budget (§10).
- `web-e2e` (ubuntu, needs `web-build` output): start `chromedriver`, then
  `flutter drive -d chrome --wasm --web-header=… --driver=test_driver/integration_test.dart
  --target=integration_test/simple_test.dart`, running a browser test that compiles a two-page
  document, asserts `pageCount == 2`, renders page 0 as SVG, renders page 0 as raster
  (non-empty RGBA, correct dimensions), exports a PDF (`%PDF` magic), and pumps a `TypstView`
  widget. Both `--wasm` and the plain JS build are exercised at least once.
- `dart-lint`/`rust-lint` unchanged — no `dart:io` may creep into `lib/` (a lint-visible rule, not
  a comment).

`release.yml`

- New `build-web` job on tag → artifact `typst_flutter_web.tar.gz` + `.sha256` sidecar.
- `generate-checksums` gains it in `needs:`, so it lands in `SHA256SUMS` automatically.
- `publish-dart` unchanged (no wasm in the published package).

## 8. Testing strategy

| Layer | What | Where |
|---|---|---|
| Rust unit | spec scanning, archive injection, transitive-spec discovery, `NotPrefetched` on wasm-only path (behind `cfg`), existing package/unpack tests | `rust/src/package/mod.rs` tests |
| Dart unit | prefetcher loop with a mocked `http.Client` (success, 404, cycle guard, transitive deps, cached specs not re-fetched) | `test/` (host VM, no FFI needed) |
| Browser e2e | compile → pageInfo → SVG → raster → PDF → `TypstView` pump, run with `--wasm` and with the JS build | `example/integration_test/web_test.dart` + `test_driver/integration_test.dart` |
| Native regression | existing `just test`, `just test-rust`, `just test-integration` must stay green after the FRB upgrade | CI |

## 9. What is left to the builder

- Exact `wasm-bindgen`/`wasm-pack` versions and whether `wasm-opt` needs to be disabled or tuned
  for size; the size budget adjustment if the first measured artifact lands above 12 MB.
- Whether the `pkg/` directory should also be discoverable from a `--dart-define`
  (useful for CDN-hosted bundles) or only via the `webModuleRoot` parameter.
- Precise CMake/podspec/Gradle interplay — none should be touched, but confirm the setup script's
  native path still runs for non-web consumers after the FRB bump.
- Whether `TypstView` raster mode needs `pixelsPerPt` guidance on web (memory: a 1 GiB ceiling
  covers roughly 250 A4 pages at 2 px/pt per rendered page, but pages are rendered lazily).
- Test-driver wiring details for `flutter drive` on web (chromedriver startup, headers passed to
  both the app and driver).

## 10. Limits and budgets

- **Wasm size budget:** ≤ 12 MB raw / ≤ 4 MB brotli-gzipped, measured in CI on the release build.
  If exceeded, levers in order: move the three bundled fonts (2.0 MB total) out of
  `include_bytes!` into Flutter assets loaded via the existing `addFonts`, tighten LTO/size
  flags, then revisit Dart-side font subsetting (P2).
- **Memory:** 1 GiB wasm instance cap (FRB default). Document; do not raise silently.
- **Threading:** one FRB worker runs a compile; Typst-internal parallelism is serial on web.
  Two concurrent `compile()` calls therefore interleave on the worker pool, they do not
  parallelise inside a document.

## 11. Risks

| Risk | Mitigation |
|---|---|
| FRB `2.14.0-beta.2` is a prerelease; regressions on native platforms | Exact pin; full native CI matrix must pass before the web work merges; note in CHANGELOG. |
| A prerelease dependency is **not** matched by `^2.13.0`, so any app that also uses another FRB plugin (or pins `^2.13.x`) gets a resolution conflict with `typst_flutter` 3.1.0; `pana` may also score the prerelease dependency down | Decide the release channel before publishing (§12). The code is identical either way; only the published version string/channel changes. |
| `typst` 0.15 (10 crates) has an unexpected wasm compile failure | Spike first (step 1 of the plan): build wasm and fix dependency-level issues before any API work. Fixes are `cfg`-gated, never native-affecting. |
| COOP/COEP adoption friction; some hosts cannot set headers | Docs with per-host snippets; explicit unsupported-host callout; option C kept as a documented fallback if it blocks users. |
| `flutter_svg`/`archive`/`http` may not all be `dart2wasm`-clean | e2e runs both `--wasm` and JS builds; raster mode is the documented fallback for SVG. |
| Wasm size over budget | §10 lever list; CI fails loudly rather than shipping silently. |
| Safari quirks (shared memory, nested workers) | We do not nest workers (FRB's pool is spawned from the main-thread module); document Safari ≥ 16.4 and verify the e2e in Chrome and once manually in Safari. |
| **Local environment:** the current `nono` sandbox grants only read access to `~/.cargo` and `~/.rustup` | Implementation requires `--write ~/.cargo --write ~/.rustup` (nightly toolchain, `rust-src`, `wasm32-unknown-unknown`, `wasm-pack`, new crates) and network access to crates.io/static.rust-lang.org. This must be granted before step 1 or the spike cannot run. |

## 12. Release channel (decided)

**Decided 2026-10-30: option 2 — publish as `3.1.0-beta.1`.**

`2.14.0-beta.2` is a prerelease, so it is not matched by the `^2.13.0` range the package ships today.
Because pub resolves a single `flutter_rust_bridge` version per app, publishing `typst_flutter` 3.1.0
with a prerelease pin would force every consumer — including anyone who also uses another FRB-based
plugin — onto the beta. Two ways to ship the same code:

1. **Stable channel, 3.1.0:** simplest for this repo, roughest for consumers.
2. **Prerelease channel, `3.1.0-beta.1`:** opt-in for web users (`dependency_overrides` or an explicit
   prerelease constraint), stable users unaffected, and it buys time for FRB 2.14.0 stable before a
   non-prerelease 3.1.0 follows.

The plan is identical for both: only the version string, the CHANGELOG wording, and whether the
release workflow's `publish-dart` job runs on the tag differ.
