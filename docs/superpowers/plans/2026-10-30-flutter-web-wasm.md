# Flutter Web (WASM) Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `typst_flutter` compile, render and preview Typst documents in a browser running a Flutter app compiled to WebAssembly, with the same Dart API native platforms use.

**Architecture:** The Rust crate is compiled to threaded `wasm32-unknown-unknown` with `flutter_rust_bridge_codegen build-web` and loaded by a small Dart loader that injects the `wasm-bindgen` glue; FRB's wasm worker pool runs compile/render/export off the main thread. Package tarballs are fetched in Dart (`package:http`) before compilation and injected into the Rust resolver cache, because `World::file()` is synchronous. Artifacts are distributed as a release tarball unpacked into the consuming app's `web/pkg/` by `dart run typst_flutter:setup --web`.

**Tech Stack:** Rust 2024, Typst 0.15, flutter_rust_bridge 2.14.0-beta.2 (exact pin), Flutter 3.47 / Dart 3.13, `wasm-pack`, nightly Rust + `-Z build-std=std,panic_abort`, Flutter web `--wasm` (dart2wasm) and JS builds.

**Spec:** `docs/superpowers/specs/2026-10-30-flutter-web-wasm-design.md`

## Global Constraints

- FRB pin is exactly `2.14.0-beta.2` in both `pubspec.yaml` and `rust/Cargo.toml`; no caret, no range.
- Package version becomes `3.1.0-beta.1` (spec §12).
- `lib/` must import neither `dart:io` nor `dart:ffi` (spec §5).
- Codegen config stays untouched: `flutter_rust_bridge.yaml` keeps `webPrefix: 'pkg/'`; no generated file is hand-edited.
- Wasm size budget: ≤ 12 MB raw and ≤ 4 MB brotli. CI fails above it.
- Wasm memory ceiling is 1 GiB (FRB default rustflags). Never raised silently.
- Native platforms keep current behaviour: no `cfg` change may alter the non-wasm code path; the full native test suite runs green after every task that touches Rust.
- No new binaries in git and none in the published package; web artifacts come from GitHub Releases via `bin/setup.dart --web`.
- `dart run typst_flutter:setup` without `--web` must not write anything into `web/`.
- Every WASM-facing API addition is additive; `TypstCompiler.compile`'s signature does not change.

## Review Focus

- **A package that fails to download (404, CORS block, offline).** A user expects a `TypstCompileException` naming the spec and URL; not a hang, not a silent empty document. Pinned by a test in Task 8.
- **`#import "@preview/..."` inside an included `.typ` file, not the main markup.** A user expects transitive imports to be found and fetched. Pinned by a test in Task 8.
- **Recompiling the same document repeatedly (live preview/typing).** A user expects zero new network requests once a package is cached. Pinned by a test in Task 8.
- **A missing or stale `web/pkg` bundle (setup not run, or package upgraded without re-running setup).** A user expects an actionable `TypstWebSetupException`; never a blank screen or a `await` that never completes. Pinned by a test in Task 7.
- **`dart:io`/`dart:ffi` creeping back into `lib/`.** A user expects the package to keep building for web. Pinned by a test in Task 6.

---

### Task 1: Port the Rust crate to `wasm32-unknown-unknown`

**Files:**
- Modify: `rust/Cargo.toml`
- Modify: `rust/src/package/mod.rs`
- Modify: `rust/src/world/mod.rs`
- Modify: `rust/src/api/typst.rs` (only the `pre_resolve_packages` call site)
- Test: `rust/src/package/mod.rs` (existing `mod tests`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `PackageError::NotPrefetched { spec: PackageSpec }`; `SimpleWorld::pre_resolve_packages()` returning `Result<(), TypstCompileError>` that is a no-op on wasm; a crate that compiles for `wasm32-unknown-unknown`.

- [ ] **Step 1: Split target-specific dependencies in `rust/Cargo.toml`**

Move the `ureq` line out of `[dependencies]` into a new section, and add the wasm-only section:

```toml
[target.'cfg(not(target_family = "wasm"))'.dependencies]
ureq = "3"

[target.'cfg(target_family = "wasm")'.dependencies]
js-sys = "0.3"
```

- [ ] **Step 2: Write the failing test for the wasm-only error path**

In `rust/src/package/mod.rs`'s `mod tests`, add a test that pins the message a web user sees when a package was never prefetched. It must compile on every target, so it constructs the error directly rather than going through a network call:

```rust
#[test]
fn test_not_prefetched_error_is_actionable() {
    let spec = PackageSpec::new(
        EcoString::from("preview"),
        EcoString::from("cetz"),
        PackageVersion::new(0, 3, 4),
    );
    let msg = PackageError::NotPrefetched { spec }.to_string();
    assert!(msg.contains("prefetch"), "message must name the fix: {msg}");
    assert!(msg.contains("@preview/cetz:0.3.4"), "message must name the spec: {msg}");
}
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `cd rust && cargo test package::tests::test_not_prefetched_error_is_actionable`
Expected: FAIL — `no variant or associated item named 'NotPrefetched'`.

- [ ] **Step 4: Implement the error variant and gate the network branch**

In `PackageError`, add:

```rust
#[error("package {0} is not available locally; call TypstCompiler.prefetchPackages (web builds cannot download packages during compilation)")]
NotPrefetched(PackageSpec),
```

In `ensure_package`, keep the cached fast path, `allow_packages` check, namespace check and URL construction shared, then replace the single download statement so it is compiled only for native:

```rust
#[cfg(not(target_family = "wasm"))]
let files = {
    let response = ureq::get(&url).call().map_err(|e| PackageError::Download {
        spec: spec.clone(),
        url: url.clone(),
        source: Box::new(e),
    })?;
    let mut compressed = Vec::new();
    response
        .into_body()
        .as_reader()
        .read_to_end(&mut compressed)
        .map_err(|e| PackageError::ReadBody { spec: spec.clone(), source: e })?;
    Self::unpack_package_archive(&compressed, spec)?
};

#[cfg(target_family = "wasm")]
let files = return Err(PackageError::NotPrefetched(spec.clone()).into());
```

(`url` is then unused on wasm — keep the `let url = …` under `#[cfg(not(target_family = "wasm"))]` so clippy stays quiet.)

- [ ] **Step 5: Gate the pre-resolve pass at the call site**

In `rust/src/api/typst.rs`, `TypstEngine::compile`, replace the unconditional pre-resolve with:

```rust
// On web the resolver cannot fetch during compilation; the Dart side injects
// archives beforehand via `add_package_archives`.
#[cfg(not(target_family = "wasm"))]
if allow_packages {
    self.world.pre_resolve_packages()?;
}
#[cfg(target_family = "wasm")]
let _ = allow_packages;
```

- [ ] **Step 6: Port `today()`**

In `rust/src/world/mod.rs`, replace the `SystemTime` fallback:

```rust
let base_timestamp = self.sys_time.unwrap_or_else(|| {
    #[cfg(not(target_family = "wasm"))]
    {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
    }
    #[cfg(target_family = "wasm")]
    {
        (js_sys::Date::now() / 1000.0) as i64
    }
});
```

- [ ] **Step 7: Verify native still passes and wasm now type-checks**

Run: `cd rust && cargo test && cargo clippy --all-targets --all-features -- -D warnings`
Expected: PASS (identical behaviour to before).
Run: `cd rust && cargo check --target wasm32-unknown-unknown`
Expected: compiles with no errors. If a dependency refuses to build for wasm, fix it with the smallest `cfg` or feature change that does not touch the native path, and record what and why in the commit message.

- [ ] **Step 8: Commit**

```bash
git add rust/Cargo.toml rust/src/package/mod.rs rust/src/world/mod.rs rust/src/api/typst.rs rust/Cargo.lock
git commit -m "feat(rust): port the compiler core to wasm32-unknown-unknown"
```

---

### Task 2: Produce a wasm bundle with `build-web` and record its size

**Files:**
- Modify: `justfile` (new `build-web` recipe)
- Modify: `.gitignore` (ignore generated web artifacts)

**Interfaces:**
- Consumes: Task 1's wasm-capable crate.
- Produces: `example/web/pkg/typst_flutter.js` and `example/web/pkg/typst_flutter_bg.wasm`; the `just build-web` recipe every later task uses.

- [ ] **Step 1: Install the web toolchain**

```bash
rustup toolchain install nightly
rustup +nightly component add rust-src
rustup +nightly target add wasm32-unknown-unknown
cargo install wasm-pack
cargo install flutter_rust_bridge_codegen --version 2.14.0-beta.2 --locked
```

Expected: `wasm-pack --version` and `flutter_rust_bridge_codegen --version` both succeed (`2.14.0-beta.2`). Do not continue until they do.

- [ ] **Step 2: Add the `justfile` recipe**

```make
# Build the WebAssembly bundle into example/web/pkg
build-web:
    flutter_rust_bridge_codegen build-web --release -o example/web
```

- [ ] **Step 3: Run the build**

Run: `just build-web`
Expected: `example/web/pkg/typst_flutter.js` and `example/web/pkg/typst_flutter_bg.wasm` exist, and the command exits 0.

- [ ] **Step 4: Record the measurements**

Run: `ls -l example/web/pkg/*.wasm && shasum -a 256 example/web/pkg/*.wasm && gzip -9 -c example/web/pkg/typst_flutter_bg.wasm | wc -c`
Expected: the raw size is recorded in the commit message. If raw > 12 MB, stop and apply the spec's §10 levers (move the 2.0 MB of fonts to Flutter assets first) before continuing.

- [ ] **Step 5: Commit**

```bash
git add justfile .gitignore
git commit -m "build: add just build-web for the wasm bundle

Raw wasm size: <N> bytes"
```

---

### Task 3: Upgrade flutter_rust_bridge to 2.14.0-beta.2

**Files:**
- Modify: `pubspec.yaml`
- Modify: `rust/Cargo.toml`
- Regenerate: `lib/src/rust/**`, `rust/src/frb_generated.rs`

**Interfaces:**
- Consumes: Task 2's toolchain (the codegen binary is already the right version).
- Produces: generated bindings whose `codegenVersion` is `2.14.0-beta.2`, and a `flutter_rust_bridge_for_generated_web.dart` that exports `initializeWasmModule` and `ExternalLibrary`.

- [ ] **Step 1: Bump both pins**

`pubspec.yaml`: `flutter_rust_bridge: 2.14.0-beta.2`
`rust/Cargo.toml`: `flutter_rust_bridge = "=2.14.0-beta.2"`

- [ ] **Step 2: Regenerate**

Run: `flutter pub get && just gen`
Expected: `lib/src/rust/frb_generated.dart` reports `String get codegenVersion => '2.14.0-beta.2';` and `git diff --stat` shows only regenerated files.

- [ ] **Step 3: Prove native is unaffected**

Run: `just build-host && just test && just test-rust`
Expected: all existing tests PASS. Any failure here stops the whole plan: do not build web features on a broken bridge.

- [ ] **Step 4: Prove the wasm build still works with the new bridge**

Run: `just build-web`
Expected: exits 0; artifact sizes within a few percent of Task 2's numbers.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock rust/Cargo.toml rust/Cargo.lock lib/src/rust rust/src/frb_generated.rs
git commit -m "build: upgrade flutter_rust_bridge to 2.14.0-beta.2 for dart2wasm support"
```

---

### Task 4: Example app on web — scaffold and interop spike

**Files:**
- Create: `example/web/index.html`, `example/web/manifest.json` (via `flutter create`)
- Create: `example/lib/web_probe.dart` (throwaway, deleted in the last step of this task)
- Modify: `example/lib/main.dart` (temporary probe entry)
- Modify: `example/justfile`

**Interfaces:**
- Consumes: Task 3's bridge and Task 2's `just build-web`.
- Produces: confirmation of spec §7.0 Spike B (opaque handles are shared, sync+async must not overlap), the `example/justfile` `run-web` recipe, and a `web/` scaffold Task 10 reuses.

- [ ] **Step 1: Scaffold web support for the example**

Run: `cd example && flutter create --platforms=web .`
Expected: `example/web/index.html` and `example/web/manifest.json` exist; `example/android`, `ios`, `macos`, `linux`, `windows` are untouched (`git status` shows no changes under them).

- [ ] **Step 2: Add the dev recipe with the required headers**

In `example/justfile`:

```make
# Run on Chrome with WebAssembly and cross-origin isolation
run-web:
    flutter run -d chrome --wasm \
      --web-header=Cross-Origin-Opener-Policy=same-origin \
      --web-header=Cross-Origin-Embedder-Policy=require-corp
```

- [ ] **Step 3: Write the probe**

`example/lib/web_probe.dart` — a single button that runs the sequence and renders each outcome as text, so a wrong answer is visible rather than silent:

```dart
import 'package:typst_flutter/typst_flutter.dart';

/// Runs the Spike B interop sequence and returns a human-readable log.
Future<String> runWebProbe() async {
  final log = StringBuffer();
  final compiler = await TypstCompiler.create();
  log.writeln('create: ok');

  final doc = await compiler.compile(source: '= Hello\n#pagebreak()\nPage two');
  log.writeln('compile: ${doc.pageCount} pages');

  log.writeln('pageInfo: ${doc.pageInfo(0).widthPt}pt');
  final raster = await doc.renderRaster(pageIndex: 0, pixelsPerPt: 2);
  log.writeln('raster: ${raster.width}x${raster.height}, ${raster.bytes.length} bytes');
  final svg = await doc.renderSvg(0);
  log.writeln('svg: ${svg.length} chars');
  final pdf = await doc.exportPdf();
  log.writeln('pdf: ${pdf.length} bytes, magic ${String.fromCharCodes(pdf.take(4))}');

  // Deliberate overlap: a sync call while an async render is in flight.
  final pending = doc.renderRaster(pageIndex: 0, pixelsPerPt: 4);
  try {
    doc.pageInfo(0);
    log.writeln('overlap: sync call succeeded (no lock error)');
  } catch (e) {
    log.writeln('overlap: sync call failed as documented -> $e');
  }
  await pending;

  doc.dispose();
  compiler.dispose();
  return log.toString();
}
```

Check `renderRaster`'s exact signature in `lib/src/document.dart` before writing it and match the parameter names it actually has.

- [ ] **Step 4: Run the probe in both web compilations**

Run: `just build-web && cd example && flutter run -d chrome --wasm --web-header=Cross-Origin-Opener-Policy=same-origin --web-header=Cross-Origin-Embedder-Policy=require-corp`
Then the same without `--wasm`.
Expected: `create/compile/pageInfo/raster/svg/pdf` all log successful values under **both** builds, and the overlap line reports a caught error rather than a deadlock or a frozen tab. Record both logs in the commit message. If `--wasm` fails where the JS build works, that is a Spike B failure: stop and reopen the approach question (spec §6) instead of working around it.

- [ ] **Step 5: Remove the probe and commit the scaffold**

Delete `example/lib/web_probe.dart` and revert the temporary `main.dart` changes (the real e2e test arrives in Task 10).

```bash
git add example/web example/justfile
git commit -m "feat(example): web platform scaffold and run-web recipe"
```

---

### Task 5: Rust prefetch API — scan, cache introspection, archive injection

**Files:**
- Modify: `rust/src/package/mod.rs`
- Modify: `rust/src/api/typst.rs`
- Regenerate: `lib/src/rust/**`, `rust/src/frb_generated.rs`
- Test: `rust/src/package/mod.rs` (`mod tests`)

**Interfaces:**
- Consumes: Task 1's `NotPrefetched` and Task 3's bridge.
- Produces (used by Tasks 8 and 10):
  - `pub struct PackageArchive { pub spec: String, pub bytes: Vec<u8> }`
  - `#[frb(sync)] TypstEngine::scan_package_specs(&self, markup: &str, files: Vec<VirtualFile>) -> Vec<String>` — spec strings in `@namespace/name:version` form.
  - `#[frb(sync)] TypstEngine::cached_package_specs(&self) -> Vec<String>` — same form.
  - `TypstEngine::add_package_archives(&mut self, archives: Vec<PackageArchive>) -> Result<Vec<String>, String>` — returns specs still unresolved after injection (transitive deps).
  - `PackageResolver::insert_package_archive(&self, spec: &PackageSpec, bytes: &[u8]) -> Result<Vec<PackageSpec>, FileError>`

- [ ] **Step 1: Write the failing Rust tests**

In `rust/src/package/mod.rs`'s `mod tests` (reuse the existing `gz_tar`-style helper from `test_package_download_*`):

```rust
#[test]
fn test_insert_package_archive_reports_transitive_specs() {
    let resolver = PackageResolver::new();
    let spec = PackageSpec::new(
        EcoString::from("preview"),
        EcoString::from("outer"),
        PackageVersion::new(0, 1, 0),
    );
    let archive = gz_tar(&[
        ("typst.toml", "[package]\nname = \"outer\"\nversion = \"0.1.0\"\nentrypoint = \"lib.typ\"\n"),
        ("lib.typ", "#import \"@preview/inner:0.2.0\": *\n= Outer\n"),
    ]);

    let unresolved = resolver.insert_package_archive(&spec, &archive).unwrap();

    assert_eq!(unresolved.len(), 1);
    assert_eq!(unresolved[0].to_string(), "@preview/inner:0.2.0");
    assert!(resolver.cache.read().unwrap().contains_key(&spec));
}

#[test]
fn test_insert_package_archive_twice_is_idempotent() {
    let resolver = PackageResolver::new();
    let spec = PackageSpec::new(
        EcoString::from("preview"),
        EcoString::from("outer"),
        PackageVersion::new(0, 1, 0),
    );
    let archive = gz_tar(&[("lib.typ", "= Outer\n")]);
    resolver.insert_package_archive(&spec, &archive).unwrap();
    let second = resolver.insert_package_archive(&spec, &archive).unwrap();
    assert!(second.is_empty());
    assert_eq!(resolver.cache.read().unwrap().len(), 1);
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `cd rust && cargo test package::tests::test_insert_package_archive`
Expected: FAIL — `no method named 'insert_package_archive'`.

- [ ] **Step 3: Implement `insert_package_archive`**

In `impl PackageResolver`, after `unpack_package_archive`:

```rust
/// Injects an already-downloaded package archive into the cache and returns
/// any package specs it newly references.
pub(crate) fn insert_package_archive(
    &self,
    spec: &PackageSpec,
    compressed: &[u8],
) -> Result<Vec<PackageSpec>, FileError> {
    let files = Self::unpack_package_archive(compressed, spec)?;
    let mut referenced = Vec::new();
    for (path, bytes) in &files {
        if path.ends_with(".typ")
            && let Ok(text) = std::str::from_utf8(bytes)
        {
            self.collect_package_specs(text, &mut referenced);
        }
    }
    let mut cache = self
        .cache
        .write()
        .map_err(|e| PackageError::Lock(e.to_string()))?;
    cache.insert(spec.clone(), files);
    referenced.retain(|s| s != spec && !cache.contains_key(s));
    referenced.dedup();
    Ok(referenced)
}
```

- [ ] **Step 4: Run the Rust tests**

Run: `cd rust && cargo test package::tests`
Expected: PASS.

- [ ] **Step 5: Expose the bridge API**

In `rust/src/api/typst.rs`:

```rust
/// A package archive downloaded by the caller (web prefetch path).
#[derive(Debug, Clone)]
pub struct PackageArchive {
    /// Package spec in `@namespace/name:version` form.
    pub spec: String,
    /// Raw `.tar.gz` bytes as served by the registry.
    pub bytes: Vec<u8>,
}
```

and on `impl TypstEngine`:

```rust
/// Returns `@namespace/name:version` specs referenced by [markup] and [files].
#[frb(sync)]
pub fn scan_package_specs(&self, markup: &str, files: Vec<VirtualFile>) -> Vec<String> {
    let mut specs = Vec::new();
    self.world.resolver().collect_package_specs(markup, &mut specs);
    for file in &files {
        if file.path.ends_with(".typ")
            && let Ok(text) = std::str::from_utf8(&file.bytes)
        {
            self.world.resolver().collect_package_specs(text, &mut specs);
        }
    }
    specs.iter().map(|s| s.to_string()).collect()
}

/// Returns `@namespace/name:version` specs already cached by this engine.
#[frb(sync)]
pub fn cached_package_specs(&self) -> Vec<String> {
    self.world
        .resolver()
        .cache
        .read()
        .map(|c| c.keys().map(|s| s.to_string()).collect::<Vec<_>>())
        .unwrap_or_default()
}

/// Injects downloaded archives; returns specs still unresolved (transitive deps).
pub fn add_package_archives(
    &mut self,
    archives: Vec<PackageArchive>,
) -> Result<Vec<String>, String> {
    let mut unresolved = Vec::new();
    for archive in archives {
        let spec = PackageSpec::parse(&archive.spec).map_err(|e| format!("{}: {e}", archive.spec))?;
        let specs = self
            .world
            .resolver()
            .insert_package_archive(&spec, &archive.bytes)
            .map_err(|e| format!("{spec}: {e}"))?;
        unresolved.extend(specs.iter().map(|s| s.to_string()));
    }
    Ok(unresolved)
}
```

Add the accessor `resolver()` to `SimpleWorld` in `world/mod.rs` (`pub(crate) fn resolver(&self) -> &PackageResolver`). `collect_package_specs` already takes `&self`, so no mutability is needed. Verify `PackageSpec::parse` is the right constructor for a `"@preview/name:1.2.3"` string in Typst 0.15; if it is not, use the API the crate exposes and note it.

- [ ] **Step 6: Regenerate and confirm the whole workspace builds**

Run: `just gen && cd rust && cargo test`
Expected: PASS, and `lib/src/rust/api/typst.dart` now contains `scanPackageSpecs`, `cachedPackageSpecs`, `addPackageArchives` and `PackageArchive`.

- [ ] **Step 7: Commit**

```bash
git add rust/src lib/src/rust
git commit -m "feat(rust): add package prefetch API (scan, cache introspection, archive injection)"
```

---

### Task 6: Remove `dart:ffi` from the public Dart surface and add a platform guard test

**Files:**
- Modify: `lib/src/compiler.dart:1` and `:29`
- Create: `test/platform_imports_test.dart`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a `lib/` tree that imports neither `dart:io` nor `dart:ffi`, and a test every later task must keep green.

- [ ] **Step 1: Write the failing guard test**

`test/platform_imports_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ never imports dart:io or dart:ffi', () {
    final offenders = <String>[];
    for (final e in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = e.readAsStringSync();
      if (RegExp(r'''import\s+'dart:(io|ffi)''').hasMatch(src)) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty, reason: 'these files break the web build: $offenders');
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `flutter test test/platform_imports_test.dart`
Expected: FAIL listing `lib/src/compiler.dart`.

- [ ] **Step 3: Drop the import and the marker interface**

`lib/src/compiler.dart`: delete `import 'dart:ffi';` and change the class declaration to:

```dart
class TypstCompiler {
```

Leave `dispose()` and its documentation untouched.

- [ ] **Step 4: Run the guard test and the full suite**

Run: `flutter test test/platform_imports_test.dart && just test`
Expected: PASS. `PlatformInt64`/`PlatformInt64Util` keep working — they come from `package:flutter_rust_bridge`, not `dart:ffi`.

- [ ] **Step 5: Note the change in `CHANGELOG.md`**

Under the new `3.1.0-beta.1` heading, add: `TypstCompiler no longer implements dart:ffi's Finalizable (the marker was web-hostile); call dispose() as before.`

- [ ] **Step 6: Commit**

```bash
git add lib/src/compiler.dart test/platform_imports_test.dart CHANGELOG.md
git commit -m "fix: drop dart:ffi from lib/ so the package can build for web"
```

---

### Task 7: Web module loader, global config and setup exception

**Files:**
- Create: `lib/src/web/loader.dart`
- Create: `lib/src/web/loader_web.dart`
- Create: `lib/src/web/loader_stub.dart`
- Create: `lib/src/config.dart`
- Modify: `lib/src/exceptions.dart`
- Modify: `lib/src/compiler.dart` (init path only)
- Modify: `lib/typst_flutter.dart` (exports)
- Test: `test/web_setup_exception_test.dart`

**Interfaces:**
- Consumes: Task 3's `flutter_rust_bridge_for_generated_web.dart` (exports `initializeWasmModule`, `ExternalLibrary`).
- Produces (used by Tasks 8 and 10):
  - `TypstFlutter.configure({String? webModuleRoot, String? packageRegistryUrl})` and `TypstFlutter.webModuleRoot` / `TypstFlutter.packageRegistryUrl` getters defaulting to `'pkg/typst_flutter'` and `'https://packages.typst.org'`.
  - `TypstWebSetupException(this.message, {this.cause})` with `framework`-style `toString()`.
  - `TypstWebSetupException describeInitFailure(Object error)` — pure function mapping any init failure to the actionable exception (this is what the test pins).
  - `Future<void> installWebModule({required String root})` from `lib/src/web/loader.dart` (conditional import; no-op on native).

- [ ] **Step 1: Write the failing test**

`test/web_setup_exception_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/typst_flutter.dart';

void main() {
  test('content hash mismatch is reported as stale setup, with the fix', () {
    final e = describeInitFailure(
      StateError('The content hash of the Rust code does not match the Dart code'),
    );
    expect(e, isA<TypstWebSetupException>());
    expect(e.message, contains('dart run typst_flutter:setup --web'));
    expect(e.message, contains('stale'));
  });

  test('unknown failures keep the original error for debugging', () {
    final cause = Exception('boom');
    final e = describeInitFailure(cause);
    expect(e.cause, same(cause));
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `flutter test test/web_setup_exception_test.dart`
Expected: FAIL — `describeInitFailure` is not defined.

- [ ] **Step 3: Add the exception and the mapper**

In `lib/src/exceptions.dart`:

```dart
/// Thrown when the WebAssembly bundle is missing, stale, or failed to load.
class TypstWebSetupException extends TypstException {
  TypstWebSetupException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'TypstWebSetupException: $message${cause == null ? '' : '\nCaused by: $cause'}';
}

/// Maps any failure from `RustLib.init()` on web into an actionable exception.
TypstWebSetupException describeInitFailure(Object error) {
  final text = error.toString();
  final isStale = text.contains('content hash') || text.contains('codegen version');
  final message = isStale
      ? 'The WebAssembly bundle in web/pkg is stale (built from a different '
            'version of typst_flutter). Re-run: dart run typst_flutter:setup --web'
      : 'Failed to initialise the Typst WebAssembly module. Make sure '
            'web/pkg/typst_flutter.js and typst_flutter_bg.wasm exist and that '
            'the page is served with Cross-Origin-Opener-Policy: same-origin and '
            'Cross-Origin-Embedder-Policy: require-corp. If they are missing, run: '
            'dart run typst_flutter:setup --web';
  return TypstWebSetupException(message, cause: error);
}
```

- [ ] **Step 4: Run the test**

Run: `flutter test test/web_setup_exception_test.dart`
Expected: PASS.

- [ ] **Step 5: Add `TypstFlutter.configure`**

`lib/src/config.dart`:

```dart
/// Process-wide web configuration.
///
/// Call [configure] once at startup when the wasm bundle or the package
/// registry live somewhere other than the defaults. Widgets that create their
/// own compiler (`TypstView.source`, `TypstDocumentViewer`, `TypstCompilerProvider`)
/// pick these values up automatically.
abstract final class TypstFlutter {
  static String? _webModuleRoot;
  static String? _packageRegistryUrl;

  static void configure({String? webModuleRoot, String? packageRegistryUrl}) {
    _webModuleRoot = webModuleRoot ?? _webModuleRoot;
    _packageRegistryUrl = packageRegistryUrl ?? _packageRegistryUrl;
  }

  /// Defaults to `pkg/typst_flutter`, resolved against the page's base URL.
  static String get webModuleRoot => _webModuleRoot ?? 'pkg/typst_flutter';

  /// Defaults to `https://packages.typst.org`.
  static String get packageRegistryUrl =>
      _packageRegistryUrl ?? 'https://packages.typst.org';
}
```

- [ ] **Step 6: Add the loader**

`lib/src/web/loader.dart`:

```dart
export 'loader_stub.dart' if (dart.library.js_interop) 'loader_web.dart';
```

`lib/src/web/loader_stub.dart`:

```dart
/// Native platforms load a dynamic library, so there is nothing to do here.
Future<ExternalLibrary?> installWebModule({required String root}) async => null;
```

`lib/src/web/loader_web.dart` — inject the glue, fail loudly, hand FRB an `ExternalLibrary`:

```dart
import 'dart:js_interop';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_web.dart';
import 'package:web/web.dart' as web;

```dart
Future<ExternalLibrary?> installWebModule({required String root}) async {
  final script = web.HTMLScriptElement()..src = '$root.js';

  final loaded = Completer<void>();
  script.onLoad.listen((_) => loaded.complete());
  script.onError.listen((_) => loaded.completeError(
        TypstWebSetupException(
          'Could not load $root.js. Run: dart run typst_flutter:setup --web',
        ),
      ));
  web.document.head!.append(script);
  await loaded.future;

  if (web.crossOriginIsolated != true) {
    web.console.warn(
      'typst_flutter: the page is not cross-origin isolated; package downloads '
      'and the wasm worker pool need COOP/COEP headers.'
          .toJS,
    );
  }

  final wasmBindgen = web.window.getProperty('wasm_bindgen'.toJS) as JSObject;
  await wasmBindgen.callAsFunction('$root_bg.wasm'.toJS).toDart;

  return const ExternalLibrary(debugInfo: 'moduleRoot=$root');
}
```

Add `web: ^1.1.0` to `pubspec.yaml` dependencies if `package:web` is not already a transitive dependency of `flutter_rust_bridge` (`flutter pub deps | grep '^web'` to check; declare it explicitly either way, since we import it directly).

- [ ] **Step 7: Wire it into `TypstCompiler.create`**

In `lib/src/compiler.dart`, replace the existing init block with a single form that works on both platforms (`RustLib.init` accepts a nullable `externalLibrary`):

```dart
static Future<TypstCompiler> create({
  FontSource? fonts,
  String? webModuleRoot,
  String? packageRegistryUrl,
  http.Client? httpClient,
}) async {
  try {
    final library = kIsWeb
        ? await installWebModule(root: webModuleRoot ?? TypstFlutter.webModuleRoot)
        : null;
    await RustLib.init(externalLibrary: library);
  } on StateError catch (e) {
    if (!e.message.contains('twice')) {
      rethrow;
    }
  } on Object catch (e) {
    if (!kIsWeb) rethrow;
    throw describeInitFailure(e);
  }
  // ... unchanged engine/font creation
}
```

- [ ] **Step 8: Export and verify**

Add to `lib/typst_flutter.dart`: `export 'src/config.dart';` and `export 'src/exceptions.dart';` (exceptions may already be exported — extend it, don't duplicate).

Run: `just test && flutter analyze`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib test pubspec.yaml pubspec.lock
git commit -m "feat: web module loader, TypstFlutter.configure and TypstWebSetupException"
```

---

### Task 8: Dart package prefetcher and compile wiring

**Files:**
- Create: `lib/src/packages.dart`
- Modify: `lib/src/compiler.dart` (`compile` path)
- Test: `test/prefetcher_test.dart`

**Interfaces:**
- Consumes: Task 5's `scanPackageSpecs` / `cachedPackageSpecs` / `addPackageArchives`; Task 7's `TypstFlutter.packageRegistryUrl`.
- Produces: `PackagePrefetcher(this._engine, {required this.registryUrl, required this.httpClient})` with `Future<void> prefetch({required String markup, required List<api.VirtualFile> files})`.

- [ ] **Step 1: Write the failing tests**

`test/prefetcher_test.dart` — three behaviours from Review Focus, using `package:http/testing.dart`'s `MockClient` and a small in-memory stand-in for the Rust engine so the test runs on the VM without FFI:

```dart
class _FakeEngine implements PackageSource {
  _FakeEngine(this.referenced);
  final List<String> referenced;
  final cached = <String>{};
  final injected = <String, List<String>>{};
  int scans = 0;

  @override
  List<String> scan({required String markup, required List<String> typFiles}) {
    scans++;
    return referenced.where((s) => !cached.contains(s)).toList();
  }

  @override
  List<String> cachedSpecs() => cached.toList();

  @override
  List<String> addArchives(Map<String, List<int>> archives) {
    for (final e in archives.entries) {
      cached.add(e.key);
    }
    return injected[e.key] ?? const [];
  }
}
```

```dart
test('downloads each referenced package once and injects the bytes', () async {
  final requested = <String>[];
  final client = MockClient((req) async {
    requested.add(req.url.toString());
    return http.Response.bytes([1, 2, 3], 200);
  });
  final engine = _FakeEngine(['@preview/cetz:0.3.4']);
  final p = PackagePrefetcher(engine, registryUrl: 'https://packages.typst.org', httpClient: client);

  await p.prefetch(markup: '#import "@preview/cetz:0.3.4"', files: const []);

  expect(requested, ['https://packages.typst.org/preview/cetz-0.3.4.tar.gz']);
  expect(engine.cached, {'@preview/cetz:0.3.4'});
});

test('a 404 surfaces a TypstCompileException naming the spec and url', () async {
  final client = MockClient((req) async => http.Response('nope', 404));
  final engine = _FakeEngine(['@preview/cetz:0.3.4']);
  final p = PackagePrefetcher(engine, registryUrl: 'https://packages.typst.org', httpClient: client);

  await expectLater(
    p.prefetch(markup: '#import "@preview/cetz:0.3.4"', files: const []),
    throwsA(isA<TypstCompileException>().having(
      (e) => e.diagnostics.first.message, 'message',
      allOf(contains('@preview/cetz:0.3.4'), contains('packages.typst.org')),
    )),
  );
});

test('transitive specs returned by the engine are fetched next round', () async {
  final requested = <String>[];
  final client = MockClient((req) async {
    requested.add(req.url.path);
    return http.Response.bytes([1], 200);
  });
  final engine = _FakeEngine(['@preview/outer:0.1.0']);
  engine.injected['@preview/outer:0.1.0'] = ['@preview/inner:0.2.0'];
  final p = PackagePrefetcher(engine, registryUrl: 'https://packages.typst.org', httpClient: client);

  await p.prefetch(markup: '#import "@preview/outer:0.1.0"', files: const []);

  expect(requested, contains('/preview/outer-0.1.0.tar.gz'));
  expect(requested, contains('/preview/inner-0.2.0.tar.gz'));
});

test('cached packages are never requested again', () async {
  final requested = <String>[];
  final client = MockClient((req) async {
    requested.add(req.url.path);
    return http.Response.bytes([1], 200);
  });
  final engine = _FakeEngine(['@preview/cetz:0.3.4']);
  final p = PackagePrefetcher(engine, registryUrl: 'https://packages.typst.org', httpClient: client);

  await p.prefetch(markup: '#import "@preview/cetz:0.3.4"', files: const []);
  await p.prefetch(markup: '#import "@preview/cetz:0.3.4"', files: const []);

  expect(requested, ['/preview/cetz-0.3.4.tar.gz']);
});
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `flutter test test/prefetcher_test.dart`
Expected: FAIL — `PackagePrefetcher` / `PackageSource` are not defined.

- [ ] **Step 3: Implement `lib/src/packages.dart`**

Define the narrow `PackageSource` interface the tests use (`scan`, `cachedSpecs`, `addArchives`), an adapter that implements it over `api.TypstEngine`, and `PackagePrefetcher.prefetch` as: compute missing = scan − cached; while missing is non-empty and rounds < 8: fetch each in parallel, collect `{spec: bytes}`, call `addArchives`, set missing = returned specs minus cached; on any non-200, throw `TypstCompileException` with one `TypstDiagnostic(severity: error)` whose message contains the spec and the full URL. Also convert the `@ns/name:ver` string into the registry path `{registry}/{ns}/{name}-{ver}.tar.gz`.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/prefetcher_test.dart`
Expected: PASS (all four).

- [ ] **Step 5: Wire into `compile()`**

In `lib/src/compiler.dart`, store the injected `http.Client` and registry URL on the instance, then in `compile()`, before calling `_engine.compile`:

```dart
if (kIsWeb && allowPackages) {
  await PackagePrefetcher(
    _EnginePackageSource(_engine),
    registryUrl: _packageRegistryUrl ?? TypstFlutter.packageRegistryUrl,
    httpClient: _httpClient,
  ).prefetch(markup: source, files: virtualFiles);
}
```

- [ ] **Step 6: Verify nothing regressed**

Run: `just test && flutter analyze`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/src/packages.dart lib/src/compiler.dart test/prefetcher_test.dart
git commit -m "feat: prefetch Typst packages in Dart for web builds"
```

---

### Task 9: `setup --web` and the web release artifact

**Files:**
- Modify: `bin/setup.dart`
- Modify: `.pubignore`, `.gitignore` (confirm `web/pkg` handling)
- Modify: `.github/workflows/release.yml`
- Test: `test/setup_paths_test.dart` (pure path/flag logic)

**Interfaces:**
- Consumes: Task 2's `just build-web` output layout.
- Produces: release asset `typst_flutter_web.tar.gz` containing `pkg/typst_flutter.js` + `pkg/typst_flutter_bg.wasm`; `dart run typst_flutter:setup --web` writing `./web/pkg/` + `./web/pkg/.typst_flutter_web_version`.

- [ ] **Step 1: Write the failing test for the flag and destination logic**

```dart
test('--web without a flag writes into <cwd>/web/pkg', () {
  final o = SetupOptions.parse(['--web']);
  expect(o.includeWeb, isTrue);
  expect(o.webDestinationFor('/tmp/app'), '/tmp/app/web/pkg');
});

test('a bare run never writes into web/', () {
  final o = SetupOptions.parse([]);
  expect(o.includeWeb, isFalse);
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `flutter test test/setup_paths_test.dart`
Expected: FAIL — `SetupOptions` is not defined. (The test imports `../bin/setup.dart`; `bin/setup.dart` must therefore not run `main()` on import — it already guards with `void main(...)` only, so this is safe.)

- [ ] **Step 3: Refactor and extend `bin/setup.dart`**

Rename `_Options` to a public `SetupOptions` (keep the existing flags and behaviour), add `includeWeb` for `--web`, add `String webDestinationFor(String cwd)` returning `p.join(cwd, 'web', 'pkg')`, and add a `_downloadWeb()` step that: skips when `web/pkg/.typst_flutter_web_version` equals `_version` and `--force` is absent; otherwise downloads `typst_flutter_web.tar.gz`, verifies it against `_sha256sums`, and unpacks with the already-imported `archive` package into the destination. Print the header requirements and the `flutter run` invocation at the end of the web step. Update `--help`.

- [ ] **Step 4: Run the tests and the setup dry path**

Run: `flutter test test/setup_paths_test.dart`
Expected: PASS.
Run: `dart run bin/setup.dart --help`
Expected: help text lists `--web`.

- [ ] **Step 5: Add the release job**

In `.github/workflows/release.yml`, add a `build-web` job before `generate-checksums`:

```yaml
  build-web:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7
      - uses: dtolnay/rust-toolchain@nightly
        with:
          components: rust-src
          targets: wasm32-unknown-unknown
      - uses: subosito/flutter-action@v2
        with:
          channel: "stable"
      - run: flutter pub get
      - run: cargo install wasm-pack
      - run: cargo install flutter_rust_bridge_codegen --version 2.14.0-beta.2 --locked
      - run: flutter_rust_bridge_codegen build-web --release -o dist
      - run: tar -czf typst_flutter_web.tar.gz -C dist pkg
      - uses: actions/upload-artifact@v7
        with:
          name: web
          path: typst_flutter_web.tar.gz
```

Add `build-web` to `generate-checksums`'s `needs:` list.

- [ ] **Step 6: Commit**

```bash
git add bin/setup.dart test/setup_paths_test.dart .github/workflows/release.yml .gitignore
git commit -m "feat: setup --web and a release job for the wasm bundle"
```

---

### Task 10: Browser e2e test and CI web jobs

**Files:**
- Create: `example/integration_test/web_test.dart`
- Create: `example/test_driver/integration_test.dart`
- Modify: `example/pubspec.yaml` (dev_dependency `integration_test` is present; confirm)
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Tasks 2, 7, 8 (the complete web path).
- Produces: `web-build` and `web-e2e` CI jobs.

- [ ] **Step 1: Write the e2e test**

`example/integration_test/web_test.dart` mirrors the Task 4 probe as assertions:

```dart
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:typst_flutter/typst_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compiles, renders and exports in the browser', (tester) async {
    final compiler = await TypstCompiler.create();
    final doc = await compiler.compile(
      source: '= Hello\n#pagebreak()\nPage two',
      allowPackages: false,
    );
    expect(doc.pageCount, 2);

    final info = doc.pageInfo(0);
    expect(info.widthPt, greaterThan(0));

    final svg = await doc.renderSvg(0);
    expect(svg, contains('<svg'));

    final raster = await doc.renderRaster(pageIndex: 0, pixelsPerPt: 2);
    expect(raster.width, greaterThan(0));
    expect(raster.bytes.length, raster.width * raster.height * 4);

    final pdf = await doc.exportPdf();
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');

    doc.dispose();
    compiler.dispose();
  });

  testWidgets('TypstView renders a page on web', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TypstView.source(source: '= Hello')),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.byType(TypstView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

Matches the real Dart API: `renderSvg(int pageIndex)` returns a `String`, `renderRaster({required int pageIndex, double pixelsPerPt})` returns `TypstRenderResult{index, bytes, width, height}`, `exportPdf()` returns `Uint8List`. Add the `MaterialApp`/`Scaffold`/`TypstView` imports.

- [ ] **Step 2: Add the driver**

`example/test_driver/integration_test.dart`:

```dart
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
```

- [ ] **Step 3: Run it locally, both compilations**

Run:
```bash
just build-web
cd example && chromedriver --port=4444 &
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/web_test.dart -d chrome --wasm \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```
then the same without `--wasm`.
Expected: both runs report all tests passed. If the widget test cannot settle on web, replace `pumpAndSettle` with a bounded `pump` loop and assert on the rendered SVG string instead — but do not delete the widget assertion.

- [ ] **Step 4: Add the CI jobs**

In `.github/workflows/ci.yml`:

```yaml
  web-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: dtolnay/rust-toolchain@nightly
        with:
          components: rust-src
          targets: wasm32-unknown-unknown
      - uses: subosito/flutter-action@v2
        with:
          channel: "stable"
      - uses: Swatinem/rust-cache@v2
      - run: flutter pub get
      - run: cargo install wasm-pack
      - run: cargo install flutter_rust_bridge_codegen --version 2.14.0-beta.2 --locked
      - run: flutter_rust_bridge_codegen build-web --release -o example/web
      - name: Enforce wasm size budget
        run: |
          size=$(stat -c%s example/web/pkg/typst_flutter_bg.wasm)
          echo "wasm bytes: $size"
          test "$size" -le 12582912
          brotli=$(brotli --version >/dev/null 2>&1 && brotli -q 11 -c example/web/pkg/typst_flutter_bg.wasm | wc -c || gzip -9 -c example/web/pkg/typst_flutter_bg.wasm | wc -c)
          echo "compressed bytes: $brotli"
          test "$brotli" -le 4194304
      - run: flutter build web --wasm --web-header=Cross-Origin-Opener-Policy=same-origin --web-header=Cross-Origin-Embedder-Policy=require-corp
        working-directory: example
      - uses: actions/upload-artifact@v7
        with:
          name: example-web
          path: example/build/web
  web-e2e:
    needs: web-build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
        with:
          channel: "stable"
      - uses: nanasess/setup-chromedriver@v2
      - run: flutter pub get
        working-directory: example
      - run: chromedriver --port=4444 &
      - run: |
          flutter drive --driver=test_driver/integration_test.dart \
            --target=integration_test/web_test.dart -d chrome --wasm \
            --web-header=Cross-Origin-Opener-Policy=same-origin \
            --web-header=Cross-Origin-Embedder-Policy=require-corp
        working-directory: example
```

`web-e2e` rebuilds the wasm itself (`flutter drive` compiles the app); add the nightly/wasm-pack/codegen steps from `web-build` to it so `web/pkg` exists.

- [ ] **Step 5: Commit**

```bash
git add example/integration_test/web_test.dart example/test_driver .github/workflows/ci.yml
git commit -m "test(ci): browser e2e for web and wasm CI jobs with a size budget"
```

---

### Task 11: Documentation, copy, version and changelog

**Files:**
- Modify: `pubspec.yaml` (version, description, topics, plugin platforms)
- Modify: `README.md`
- Create: `docs/src/content/docs/guides/web.md`
- Modify: `GEMINI.md`, `todo.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above; documents only, no code.

- [ ] **Step 1: Version, description, plugin platform**

`pubspec.yaml`: `version: 3.1.0-beta.1`; `rust/Cargo.toml`: `version = "3.1.0-beta.1"` (keep both in step, they are released together); description becomes `... Compile Typst markup to PDF or rendered images on Android, iOS, macOS, Windows, Linux and the web (WebAssembly) — no server required.`; add `web`/`wasm` to `topics`; add under `flutter.plugin.platforms`:

```yaml
      web:
        dartPluginClass: TypstFlutterWeb
```

with `lib/src/web/registrar.dart` exposing `class TypstFlutterWeb { static void registerWith([Object? registrar]) {} }` (empty on purpose — the wasm is loaded by our loader, not by registration).

- [ ] **Step 2: Write the web guide**

`docs/src/content/docs/guides/web.md` must contain, in this order: the two setup commands (`dart run typst_flutter:setup --web`, `just build-web` for repo work); the required headers with copy-paste blocks for nginx, Firebase Hosting, Netlify/Cloudflare Pages and Vercel; a note that GitHub Pages cannot set them; the dev invocation with `--wasm` and both `--web-header` flags; the limitations section (1 GiB wasm memory, Typst layout is single-threaded inside one worker, `dart:io` unavailable, `TypstFlutter.configure` for CDN/module hosting); and the sync/async rule from spec §5.

- [ ] **Step 3: Fix the copy that contradicts web support**

`README.md`: replace "No WASM overhead, no WebView, no server required" and the platform list; add web to Features and Getting started (mentioning `--web`); `GEMINI.md`: correct the comparison table and the "no WASM" claims; `todo.md`: tick the P4 item and leave a line pointing at the spec path.

- [ ] **Step 4: Changelog**

`CHANGELOG.md`: `3.1.0-beta.1` heading with web support (dart2wasm and JS builds), FRB 2.14.0-beta.2, the `Finalizable` removal, `TypstFlutter.configure`, `TypstWebSetupException`, and the COOP/COEP requirement.

- [ ] **Step 5: Verify docs build and analysis is clean**

Run: `flutter analyze && (cd docs && bun install && bun run build)`
Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml README.md CHANGELOG.md GEMINI.md todo.md docs/src/content/docs/guides/web.md lib/src/web/registrar.dart
git commit -m "docs: web (WASM) support in README, guides, changelog and version 3.1.0-beta.1"
```

---

## Final verification (before any handoff)

Run, in order, and paste the output with the completion claim:

```bash
just fmt && just fmt-rust && just get && just gen
just test-rust && just test
just build-host && just test-integration
just build-web
cd documentation: flutter analyze
```

Expected: every command exits 0. `git status` shows no uncommitted generated files (i.e. `just gen` produced no diff).
