# Swift Package Manager for `typst_flutter` on iOS and macOS

Date: 2026-11-21
Status: design for approval — approach picked (static xcframework + `process()`),
builder check returned and folded in

## Intent

Flutter 3.44 uses Swift Package Manager to manage iOS and macOS native
dependencies and keeps CocoaPods in maintenance mode; the CocoaPods registry goes
read-only on 2026-12-02. `typst_flutter` is the last CocoaPods dependency in the
Narrative app, and this fork has no other consumer, so the package drops
CocoaPods for Apple platforms entirely instead of maintaining both paths.

Success is: the example app builds and runs on macOS and on an iOS
simulator/device with SwiftPM only — no `Podfile`, no `pod install`, no
CocoaPods installed on the machine — while Android, Linux, Windows and web keep
working exactly as they do today.

## Goals

- iOS and macOS integration through a `Package.swift` per platform, laid out the
  way the Flutter tool expects (`ios/typst_flutter/`, `macos/typst_flutter/`).
- The pre-built Rust binary keeps working: downloaded by
  `dart run typst_flutter:setup`, and installable from a local cargo build
  (`--local`/`--from`).
- Delete both podspecs, both `Classes/` directories, `rust_builder/`
  (Cargokit), and the `pod install`-time auto-download.
- Example app, docs, CI, justfile and the release process describe the new step.

## Non-goals

- Dart native assets / `hook/build.dart`. That is the eventual replacement for the
  whole download-and-link dance (P1 in `todo.md`) and is a separate project.
- Building the Rust crate from source for Apple platforms *inside the package's
  build*. There is no Cargokit-on-SPM equivalent worth maintaining for one
  consumer; a local build is a `just` recipe that produces an artifact for setup
  to install.
- Windows, Linux and web packaging changes.
- Publishing to pub.dev (the fork does not publish; `.pubignore` still keeps
  binaries out of any future publish).

## Anti-goals

- A build that "succeeds" but fails at runtime with a missing symbol.
- A hidden magic step that only works on one machine. Whatever the flow is, it is
  scripted (`just`), documented, and covered by an integration test.
- Two divergent binary paths (CocoaPods vs SwiftPM) shipping different builds.

## Constraints found in recon

- Dropping CocoaPods means requiring **Flutter ≥ 3.44** (SwiftPM on by default)
  and **Dart ≥ 3.12**. Inside `Package.swift` the plugin depends on
  `FlutterFramework`, which exists only from Flutter 3.41.
- Flutter 3.50's tooling (`packages/flutter_tools/lib/src/plugins.dart`) looks
  for the manifest at `<plugin>/<ios|macos>/<plugin_name>/Package.swift`,
  symlinks the plugin directory into
  `example/<platform>/Flutter/ephemeral/Packages/.packages/`, and generates
  `.package(name: "typst_flutter", …)` plus
  `.product(name: "typst-flutter", package: "typst_flutter")`. So the package
  name is `typst_flutter`, the library product must be `typst-flutter`
  (hyphens), and the target is `typst_flutter`. When the plugin directory
  basename is not usable (a git/pub-cache basename carries a ref suffix), the
  tool copies the plugin into the build dir and rewrites the manifest; either
  way `binaryTarget(path:)` resolves inside the package.
- SwiftPM refuses `binaryTarget` paths outside the package directory, so Apple
  artifacts must live in `ios/typst_flutter/` and `macos/typst_flutter/`, not in
  `.typst_flutter_prebuilt/`.
- `flutter_rust_bridge` 2.14.0-beta.2 resolves symbols at runtime
  (`loader/_io.dart`): `libtypst_flutter.dylib`, then
  `rust_builder.framework/rust_builder`, then
  `typst_flutter.framework/typst_flutter`. None of those exist for a statically
  linked binary, so the Dart side must load the process image on Apple
  platforms. `RustLib.init` accepts `externalLibrary:`, and
  `ExternalLibrary.process(iKnowHowToUseIt: true)` is the supported constructor.
- The shipped `.a` has 395 members but the crate is a single codegen unit
  (`rust/Cargo.toml`: `lto = "fat"`, `codegen-units = 1`), so pulling in that one
  object keeps every `frb_*` entry point and, transitively, all of Typst. `nm`
  on `typst_flutter.typst_flutter.<hash>-cgu.0.rcgu.o` confirms
  `_frb_get_rust_content_hash` is exported.
- `test/platform_imports_test.dart` forbids `dart:io`/`dart:ffi` in hand-written
  `lib/` code, so the loader switch cannot import `dart:io`.
- CI today: `ci.yml` runs the Dart/Rust suites on macOS/Ubuntu/Windows and the
  desktop integration test on macOS (`just test-integration`). It has no iOS
  job. `release.yml` builds the Rust iOS xcframework **on tag push** only, and
  `setup` downloads from `…/releases/download/v<version>/…`, which does not exist
  for an unreleased branch.
- The consumer app (Narrative) takes this fork as a **git dependency**, so the
  package lives in the pub cache and its directory name carries the git ref.

## Approaches

**A. Static xcframework + `process()` loader (chosen).** `Package.swift` declares
`.binaryTarget(path: "Binaries/typst_flutter.xcframework")`; the target keeps the
single Rust object alive with
`.unsafeFlags(["-Wl,-u", "-Wl,_frb_get_rust_content_hash"])`, and
`bridge_io.dart` passes `ExternalLibrary.process(iKnowHowToUseIt: true)` on
iOS/macOS. Symbols live in the app binary: nothing to embed, nothing to re-sign,
smallest output. Cost: two non-obvious mechanisms, both pinned by an integration
test and by an `nm` check.

**B. Dynamic `typst_flutter.framework`.** Wrap the Rust cdylib (already produced
next to the `.a`) in a framework xcframework with an `Info.plist` and an
`@rpath/typst_flutter.framework/typst_flutter` install name; Xcode embeds and
signs it, and FRB's existing third fallback finds it, so the loader stays
untouched. Cost: CI grows a framework-packaging step, embedding and code signing
enter every consumer build, and a stale embed becomes a runtime crash instead of
a link error. More machinery than a single-consumer fork needs.

**C. Remote `binaryTarget(url:checksum:)` pinned to the release zip (rejected).**
Removes the manual setup step for Apple, but the checksum must be rewritten in
`Package.swift` on every release, and it silently drops the `--local`/`--from`
development flow.

## The design

### Layout

```
ios/
  typst_flutter/
    Package.swift
    Sources/typst_flutter/typst_flutter.c        (dummy export; source requirement)
    Binaries/typst_flutter.xcframework/          (gitignored, written by setup)
macos/
  typst_flutter/
    Package.swift
    Sources/typst_flutter/typst_flutter.c
    Binaries/typst_flutter.xcframework/          (gitignored, written by setup)
```

`.typst_flutter_prebuilt/` stays and keeps its `.version` stamp; it now only
holds Android ABIs and the desktop/web artifacts.

### `Package.swift` (both platforms; platform floors as today)

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "typst_flutter",
    platforms: [.iOS("13.0")],              // .macOS("10.15") for the macOS package
    products: [.library(name: "typst-flutter", targets: ["typst_flutter"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(
            name: "typst_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .target(name: "typst_flutter_binary"),
            ],
            linkerSettings: [
                // SwiftPM's replacement for the podspec's -force_load. The Rust
                // crate is one codegen unit under fat LTO, so keeping this one
                // symbol keeps every frb_* entry point and all of Typst.
                .unsafeFlags(["-Wl,-u", "-Wl,_frb_get_rust_content_hash"]),
            ]
        ),
        .binaryTarget(
            name: "typst_flutter_binary",
            path: "Binaries/typst_flutter.xcframework"
        ),
    ]
)
```

`unsafeFlags` inside a package consumed through pub (a path dependency in
practice) is allowed; SwiftPM only rejects it for packages consumed as remote
*version* products.

### Dart loader

`lib/src/bridge/bridge_io.dart`, using `defaultTargetPlatform` (no `dart:io`,
because `test/platform_imports_test.dart` forbids it):

```dart
Future<void> initWithOptionalWebModule({String? webModuleRoot}) async {
  final darwin = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);
  await RustLib.init(
    externalLibrary:
        darwin ? ExternalLibrary.process(iKnowHowToUseIt: true) : null,
  );
}
```

The `iKnowHowToUseIt` assertion is satisfied: this package is the only
flutter_rust_bridge user in the app, which is a documented precondition of
`process()`.

### Setup and where the binaries live

- iOS: unpack `libtypst_flutter_ios.xcframework.zip` into
  `ios/typst_flutter/Binaries/typst_flutter.xcframework`.
- macOS: keep downloading `libtypst_flutter_macos.a`, then wrap it with
  `xcodebuild -create-xcframework -library <a> -output
  macos/typst_flutter/Binaries/typst_flutter.xcframework`. Wrapping locally is a
  deliberate call: the release asset and release workflow stay as they are, and
  any machine that can build a Flutter macOS app has `xcodebuild`.
- `--local`/`--from` take the same route for macOS. `--local` stays
  **macOS-only**: a host `cargo build` never produces an iOS artifact, so iOS
  local builds come from the recipe below, and `--from` accepts a folder
  containing a pre-built iOS xcframework zip.
- The version stamp stays authoritative, but a matching stamp is no longer
  enough: setup also verifies that both Apple xcframeworks are present when the
  host is macOS, and installs them when they are not. The check is
  **macOS-host-only** so the Gradle-triggered setup on Linux/Windows still does
  nothing Apple-related. Writes are idempotent (remove, then create).
- Consumer wiring is a **git dependency**, so the xcframeworks live in the pub
  cache: the docs, and the app's own build script, must run
  `dart run typst_flutter:setup` after `flutter pub get`, `pub upgrade`,
  `pub cache clean`/`repair`, or any change of git ref (a new ref means a new
  pub-cache directory). Local iteration on the fork uses a
  `dependency_overrides: typst_flutter: path: …` plus `setup --local`.

### Local Apple builds

- `just build-ios-local` (new): `rustup target add aarch64-apple-ios
  aarch64-apple-ios-sim x86_64-apple-ios` (failing with that exact hint if
  missing), build the three targets, `lipo` the simulator pair, then
  `xcodebuild -create-xcframework` straight into
  `ios/typst_flutter/Binaries/`.
- `just build-host` on macOS grows the second darwin arch and a `lipo`, so the
  local macOS xcframework is universal. This matters because
  `flutter build macos --release` links both arches
  (`flutter_tools/lib/src/macos/build_macos.dart`), while `ONLY_ACTIVE_ARCH=YES`
  hides the problem in Debug. `build-host` then ends with
  `dart run typst_flutter:setup --local` on macOS.
- `just setup` is the download path (`dart run typst_flutter:setup`).

### Deletions, bumps, scope of the sweep

- Delete `ios/typst_flutter.podspec`, `macos/typst_flutter.podspec`,
  `ios/Classes/`, `macos/Classes/`, `rust_builder/` (whole package).
- `android/build.gradle`: remove the Cargokit fallback branch and its
  `../rust_builder/cargokit/gradle/plugin.gradle` import; a missing prebuilt
  `.so` now fails with "run `dart run typst_flutter:setup`". This is the only
  Android change; everything else on Android is untouched.
- `pubspec.yaml`: `environment.flutter: ">=3.44.0"`, `environment.sdk: ^3.12.0`,
  version `3.2.0` (packaging breaking change; the sole consumer is on 3.50).
- `justfile`: add `setup` and `build-ios-local`; drop the `rust_builder` pub get.
- `example/ios`: run `flutter build ios`/`flutter run` once to migrate the
  project to SwiftPM, and commit the project file changes. `example/macos` is
  already migrated. Confirm no `Podfile` or `Pods/` appears.
- `.gitignore`/`.pubignore`: ignore `ios/typst_flutter/Binaries/` and
  `macos/typst_flutter/Binaries/`.
- CI: add an iOS job to `ci.yml` — `just build-ios-local` (with cargo caching)
  plus `cd example && flutter build ios --simulator --no-codesign`. Device
  builds, signing and the simulator integration test stay out of CI for now and
  are part of the local acceptance run. `release.yml` keeps its tag-push iOS job
  and its `libtypst_flutter_macos.a` asset unchanged, but its macOS step stops
  copying a bare `.a` into `.typst_flutter_prebuilt/macos`.
- Tests: `test/setup_run_test.dart` destinations move; add coverage that a
  matching stamp with missing Apple xcframeworks triggers a reinstall on macOS.
- Docs: README install section (setup is required before an Apple build, and
  after a git-ref change), `docs/src/content/docs/guides/getting-started.md`,
  `GEMINI.md` (drop the Cargokit section), `RELEASE_PROCESS.md`, `todo.md`,
  `CHANGELOG.md`.

## How we'll know it works

1. `just build-host && dart run typst_flutter:setup --local` creates
   `ios/typst_flutter/Binaries/…` (from `just build-ios-local`) and a universal
   `macos/typst_flutter/Binaries/typst_flutter.xcframework` with `macos-arm64` and
   `macos-x86_64` slices.
2. `cd example && flutter build macos --release` succeeds with no CocoaPods
   message, and `nm -g` on the built binary shows `_frb_get_rust_content_hash`
   and `_frb_dart_opaque_*`.
3. `cd example && flutter test integration_test/simple_test.dart -d macos`
   passes (compile to PDF), proving the process-loaded symbols resolve.
4. `cd example && flutter build ios --no-codesign` succeeds, and the simulator
   integration test (`flutter test integration_test/simple_test.dart -d
   "iPhone 16"`) passes.
5. `flutter test` (unit suite, mocked bridge) and `just test-rust` unchanged.
6. `grep -r podspec ios macos` and `ls rust_builder` return nothing; a build on a
   machine with no CocoaPods installed still works.

## Risks

- **Symbol prefix drift.** `_frb_get_rust_content_hash` is a generated name; a
  future flutter_rust_bridge upgrade could rename it and silently empty the app
  of Rust symbols. Mitigations: a comment next to the flag, the `nm` check, the
  integration test. Fallback if the surgical flag misbehaves: `-all_load`.
- **pub-cache lifecycle.** Because the dependency is git-based, the binaries live
  in the pub cache and vanish when the ref changes or the cache is cleaned. The
  failure mode is a SwiftPM "binary target not found" at manifest evaluation, so
  the docs make setup a step after every dependency change.
- **Flutter's plugin-identity handling.** Flutter 3.50 copies and rewrites the
  manifest when the pub-cache basename carries a version/ref suffix. If the
  consumer app reports "unable to override package", the fallback is a `path:`
  `dependency_overrides` entry while filing against flutter/flutter#186934.
- **Manifest caching in Xcode.** Adding a manifest to an existing checkout may
  need `flutter clean` and a DerivedData reset; the docs will say so.
- **Local macOS release builds.** A single-arch local build still cannot link a
  universal release app; `build-host` builds both arches to avoid the trap, and
  this is documented next to the recipe.

## Calls I made (check these while reading)

- `build-host` builds both darwin arches on macOS and chains `setup --local`;
  `setup` alone remains the downloader.
- `--local` does not attempt iOS; `just build-ios-local` does, writing straight
  into `Binaries/`.
- The Apple presence check runs only on a macOS host, so Linux/Windows Android
  builds are unaffected; the version stamp is otherwise unchanged.
- Loader switch uses `defaultTargetPlatform`, keeping `dart:io` out of `lib/`.
- iOS CI job is build-only (simulator, unsigned) with cargo caching; the
  simulator integration test is a documented local/acceptance step, not CI.
- `android/build.gradle` loses the Cargokit branch (the only Android edit).
- No `PrivacyInfo.xcprivacy` (no required-reason APIs), no new release asset,
  `Binaries/` directories are created by setup and gitignored.
