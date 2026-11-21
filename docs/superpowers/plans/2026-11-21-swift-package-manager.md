# Swift Package Manager Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship iOS and macOS support for `typst_flutter` through Swift Package Manager only, deleting every CocoaPods artifact from the package.

**Architecture:** Each Apple platform gets a SwiftPM package (`ios/typst_flutter/`, `macos/typst_flutter/`) whose target depends on a `binaryTarget` pointing at `Binaries/typst_flutter.xcframework` inside the package. `dart run typst_flutter:setup` writes those xcframeworks (downloading them, or wrapping a locally built `.a`). The Rust static library is kept alive at link time by `-Wl,-u,_frb_get_rust_content_hash`, and the Dart loader opens the process image on Darwin instead of a dylib.

**Tech Stack:** Dart 3.12+ / Flutter 3.44+, SwiftPM (swift-tools 5.9), Rust staticlib via flutter_rust_bridge 2.14.0-beta.2, `xcodebuild -create-xcframework`, Rust 1.8x `cargo`.

**Spec:** `docs/superpowers/specs/2026-11-21-swift-package-manager-design.md`

## Global Constraints

- `environment.flutter: ">=3.44.0"`, `environment.sdk: ^3.12.0`, package `version: 3.2.0`.
- SwiftPM package name is `typst_flutter`; library product name is `typst-flutter` (hyphens); target name is `typst_flutter`.
- The binary target path is exactly `Binaries/typst_flutter.xcframework`, relative to each platform package directory (`ios/typst_flutter/`, `macos/typst_flutter/`).
- Platform floors stay `.iOS("13.0")` and `.macOS("10.15")`.
- No CocoaPods anywhere: no `*.podspec`, no `Podfile`, no `pod`, no Cargokit.
- Hand-written files under `lib/` must not import `dart:io` or `dart:ffi` (enforced by `test/platform_imports_test.dart`).
- Android, Linux, Windows and web behavior is unchanged except: the Android Gradle Cargokit fallback is removed and a missing prebuilt `.so` fails with a message naming `dart run typst_flutter:setup`.
- `.typst_flutter_prebuilt/` keeps its role and `.version` stamp for non-Apple artifacts.

### Environment note (read before starting)

Xcode builds cannot run inside this session's sandbox — verified:

```
xcodebuild: error: Could not resolve package dependencies:
  sandbox-exec: sandbox_apply: Operation not permitted
```

So every step marked **EXTERNAL** is run by the human in a normal terminal outside the sandbox, and its output is pasted back before the task continues. Everything else (Dart tests, `swift package --disable-sandbox dump-package`, `xcodebuild -create-xcframework`, `lipo`, `cargo`) runs fine in-session.

## Review Focus

Failure modes the spec implies that no single task's unit tests cover. Each line names the test that pins it.

1. A consumer who forgets `dart run typst_flutter:setup` gets a loud SwiftPM resolution error, never an app that links cleanly and dies on first compile. → Task 2, step "binary target must exist".
2. `flutter build macos --release` links both arches, so a single-arch local `setup --local` build must not silently produce an arm64-only xcframework. → Task 5, `lipo -info` check on the produced slice.
3. Re-running setup (version change, `--force`, repeated `--local`) must replace the xcframework, never nest `typst_flutter.xcframework/typst_flutter.xcframework`. → Task 1, idempotence test.
4. With a git dependency, setup runs from the *app* root and must write into the pub-cache package directory, not the app directory, and a stale stamp from the CocoaPods era must not short-circuit the Apple install. → Task 1, "current stamp without Apple xcframeworks" test.
5. The host unit suite (`flutter test`, `just test-coverage`) uses `RustLib.initMock` and must never try to open a native library after the loader change. → Task 3, platform-selection unit test + full `flutter test`.

---

### Task 1: Setup installs the Apple xcframeworks into the SPM packages

**Files:**
- Modify: `bin/setup.dart`
- Modify: `lib/src/setup/setup_options.dart` (only if a helper is needed there — prefer keeping path knowledge in `bin/setup.dart`)
- Test: `test/setup_run_test.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `_Artifact.destination` becomes **package-root-relative** for every artifact; Android entries become `.typst_flutter_prebuilt/android/<abi>/libtypst_flutter.so`, desktop entries gain the `.typst_flutter_prebuilt/` prefix.
  - `const _iosXcframeworkRel = 'ios/typst_flutter/Binaries/typst_flutter.xcframework'`
  - `const _macosXcframeworkRel = 'macos/typst_flutter/Binaries/typst_flutter.xcframework'`
  - `const _macosLibraryRel = '.typst_flutter_prebuilt/macos/libtypst_flutter.a'`
  - `SetupRunner(this._opts, {…, String? hostPlatform, Future<void> Function({required String library, required String output})? createXcframework})`; `hostPlatform` defaults to `Platform.operatingSystem`, `createXcframework` defaults to a real `xcodebuild` runner.
  - Attribute the iOS artifact's `destination` to `_iosXcframeworkRel` (its zip unpacks `typst_flutter.xcframework/` into it) and the macOS `.a` artifact's `destination` to `_macosLibraryRel`.

- [ ] **Step 1: Write the failing tests**

Add a group to `test/setup_run_test.dart`:

```dart
group('apple swift package artifacts', () {
  late Directory root;
  late String packageDir;
  late String appDir;
  late List<({String library, String output})> wrapCalls;

  setUp(() {
    root = Directory.systemTemp.createTempSync('typst_setup_apple');
    packageDir = p.join(root.path, 'pkg');
    appDir = p.join(root.path, 'app');
    Directory(packageDir).createSync(recursive: true);
    Directory(appDir).createSync(recursive: true);
    wrapCalls = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// A zip shaped like `libtypst_flutter_ios.xcframework.zip`.
  List<int> iosZip() {
    final archive = Archive();
    for (final name in const [
      'typst_flutter.xcframework/Info.plist',
      'typst_flutter.xcframework/ios-arm64/libtypst_flutter.a',
    ]) {
      final bytes = utf8.encode(name);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive)!;
  }

  Future<http.Response> fakeGet(Uri url) async {
    if (url.path.endsWith('SHA256SUMS')) return http.Response('', 200);
    if (url.path.endsWith('libtypst_flutter_ios.xcframework.zip')) {
      return http.Response.bytes(iosZip(), 200);
    }
    if (url.path.endsWith('libtypst_flutter_macos.a')) {
      return http.Response.bytes(utf8.encode('staticlib'), 200);
    }
    return http.Response('not found', 404);
  }

  SetupRunner runner(List<String> extraArgs = const []) => SetupRunner(
    SetupOptions.parse(['--version', '9.9.9', '--no-verify', ...extraArgs]),
    httpGet: fakeGet,
    packageRoot: packageDir,
    hostPlatform: 'macos',
    workingDirectory: appDir,
    createXcframework: ({required library, required output}) async =>
        wrapCalls.add((library: library, output: output)),
  );

  test('unpacks the iOS xcframework inside the iOS SPM package', () async {
    await runner().run();
    expect(
      File(
        p.join(
          packageDir,
          'ios/typst_flutter/Binaries/typst_flutter.xcframework/Info.plist',
        ),
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(appDir, 'ios')).existsSync(),
      isFalse,
      reason: 'setup must write into the package, not the app that ran it',
    );
  });

  test('wraps the macOS static library into the macOS SPM package', () async {
    await runner().run();
    expect(wrapCalls, hasLength(1));
    expect(
      wrapCalls.single.library,
      p.join(packageDir, '.typst_flutter_prebuilt/macos/libtypst_flutter.a'),
    );
    expect(
      wrapCalls.single.output,
      p.join(
        packageDir,
        'macos/typst_flutter/Binaries/typst_flutter.xcframework',
      ),
    );
  });

  void writeStamp(String version) {
    final stamp = File(
      p.join(packageDir, '.typst_flutter_prebuilt', '.version'),
    )..createSync(recursive: true);
    stamp.writeAsStringSync(version);
  }

  test('re-running with --force replaces instead of nesting', () async {
    await runner().run();
    await runner(['--force']).run();
    final binDir = Directory(
      p.join(packageDir, 'ios/typst_flutter/Binaries'),
    );
    expect(
      binDir.listSync().map((e) => p.basename(e.path)).toList(),
      ['typst_flutter.xcframework'],
      reason: 'a second run must not create '
          'typst_flutter.xcframework/typst_flutter.xcframework',
    );
  });

  test('a current stamp without the Apple xcframeworks reinstalls', () async {
    writeStamp('9.9.9');

    await runner().run();
    expect(
      wrapCalls,
      hasLength(1),
      reason: 'a stamp alone must not skip the Apple install',
    );
  });

  test('a matching stamp with both xcframeworks present is up to date',
      () async {
    Directory(
      p.join(packageDir, 'ios/typst_flutter/Binaries/typst_flutter.xcframework'),
    ).createSync(recursive: true);
    Directory(
      p.join(packageDir, 'macos/typst_flutter/Binaries/typst_flutter.xcframework'),
    ).createSync(recursive: true);
    writeStamp('9.9.9');

    await runner().run();
    expect(wrapCalls, isEmpty);
  });

  test('a non-macOS host never asks for Apple artifacts', () async {
    final runner = SetupRunner(
      SetupOptions.parse(['--version', '9.9.9', '--no-verify']),
      httpGet: fakeGet,
      packageRoot: packageDir,
      hostPlatform: 'linux',
      createXcframework: ({required library, required output}) async =>
          wrapCalls.add((library: library, output: output)),
    );
    await runner.run();
    expect(wrapCalls, isEmpty);
    expect(
      Directory(p.join(packageDir, 'ios')).existsSync(),
      isFalse,
    );
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/setup_run_test.dart -n 'apple swift package artifacts'`
Expected: FAIL — `SetupRunner` has no `hostPlatform`/`createXcframework` parameters, and the iOS xcframework is written under `.typst_flutter_prebuilt/`.

- [ ] **Step 3: Implement package-relative destinations and the Apple install path in `bin/setup.dart`**

- Add the three path constants; change every `_Artifact.destination` in `_artifactsForPlatform` and `_allArtifacts` to package-relative (`'.typst_flutter_prebuilt/' + <old value>`), except the iOS zip which becomes `_iosXcframeworkRel` and the macOS `.a` which becomes `.typst_flutter_prebuilt/macos/libtypst_flutter.a`.
- `_writeArtifact` joins `_packageRoot` with `artifact.destination` directly (drop the `_prebuiltDir` join). Unzip archive entries relative to that path, as today.
- Add `hostPlatform` and `createXcframework` constructor parameters and fields; replace both `Platform.operatingSystem` reads with `_hostPlatform`.
- After the download loop and after `_installLocal`'s loop, call `await _wrapMacosLibraryIfNeeded()`: when `_hostPlatform == 'macos'` and the `.a` exists, `Directory(output).deleteSync(recursive: true)` if present, then call `_createXcframework(library: …, output: …)`. The default runner is:

```dart
Future<void> _createXcframework({
  required String library,
  required String output,
}) async {
  final result = await Process.run('xcodebuild', [
    '-create-xcframework', '-library', library, '-output', output,
  ]);
  if (result.exitCode != 0) {
    throw Exception(
      'xcodebuild -create-xcframework failed (exit ${result.exitCode}).\n'
      '${result.stderr}\n'
      'Install Xcode (with its command line tools) and re-run setup.',
    );
  }
}
```

- `_isUpToDate()` returns `stamp == version && (_hostPlatform != 'macos' || _appleXcframeworksPresent())`, where `_appleXcframeworksPresent()` checks both `ios/typst_flutter/Binaries/typst_flutter.xcframework` and `macos/typst_flutter/Binaries/typst_flutter.xcframework` exist.
- Keep `--local` unchanged in intent: on macOS it installs the `.a` from `rust/target/release` and then wraps it; the iOS xcframework can only come from a release download or `--from`.

- [ ] **Step 4: Run the new tests and the whole file**

Run: `flutter test test/setup_run_test.dart`
Expected: PASS, including the pre-existing web and local-mode groups (their assertions move to the new package-relative paths — update any path expectations that look under `.typst_flutter_prebuilt/android/…` etc.).

- [ ] **Step 5: Commit**

```bash
git add bin/setup.dart test/setup_run_test.dart
git commit -m "feat(setup): install Apple xcframeworks inside the SPM packages"
```

---

### Task 2: SwiftPM manifests for iOS and macOS

**Files:**
- Create: `ios/typst_flutter/Package.swift`
- Create: `ios/typst_flutter/Sources/typst_flutter/typst_flutter.c`
- Create: `macos/typst_flutter/Package.swift`
- Create: `macos/typst_flutter/Sources/typst_flutter/typst_flutter.c`
- Modify: `.gitignore`, `.pubignore`

**Interfaces:**
- Consumes: the `Binaries/…` locations written by Task 1.
- Produces: two packages named `typst_flutter` vending the library product `typst-flutter`, target `typst_flutter`, binary target `typst_flutter_binary`.

- [ ] **Step 1: Write `ios/typst_flutter/Package.swift`**

```swift
// swift-tools-version: 5.9
// SwiftPM manifest for typst_flutter (iOS).
//
// The Rust static library is installed as the binary target by
// `dart run typst_flutter:setup`, which writes
// Binaries/typst_flutter.xcframework inside this package.
import PackageDescription

let package = Package(
    name: "typst_flutter",
    platforms: [.iOS("13.0")],
    products: [
        .library(name: "typst-flutter", targets: ["typst_flutter"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "typst_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .target(name: "typst_flutter_binary"),
            ],
            linkerSettings: [
                // SwiftPM's replacement for the podspec's -force_load.
                // flutter_rust_bridge resolves its symbols at runtime via
                // DynamicLibrary.process(), and the Rust crate is a single
                // codegen unit under fat LTO, so forcing this one symbol keeps
                // every frb_* entry point (and all of Typst) in the app binary.
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

- [ ] **Step 2: Write `macos/typst_flutter/Package.swift`**

Identical, except `import PackageDescription` block and `.macOS("10.15")` in `platforms`, and a comment naming macOS. Keep every other line, name, product, target and flag byte-identical.

- [ ] **Step 3: Write the two stub sources**

`ios/typst_flutter/Sources/typst_flutter/typst_flutter.c` (and the same file under `macos/`):

```c
#include <stdint.h>

// SwiftPM requires at least one source file in a target. This mirrors the
// function the old podspec shipped so the plugin keeps a link-time marker.
int32_t typst_flutter_dummy_method_to_enforce_bundling(void) {
    return 0;
}
```

- [ ] **Step 4: Ignore the installed binaries**

`.gitignore`, under the "Native binaries" heading, after `.typst_flutter_prebuilt/`:

```
# Apple binaries installed by `dart run typst_flutter:setup`; SwiftPM reads
# them from inside the platform packages.
ios/typst_flutter/Binaries/
macos/typst_flutter/Binaries/
```

`.pubignore`, after `.typst_flutter_prebuilt/`:

```
# Installed by the setup script, never published.
ios/typst_flutter/Binaries/
macos/typst_flutter/Binaries/
```

- [ ] **Step 5: Verify the manifests parse and declare the required names**

Run (each package separately):

```bash
swift package --disable-sandbox --package-path ios/typst_flutter dump-package | grep -E '"name" : "(typst_flutter|typst-flutter|typst_flutter_binary|Binaries/typst_flutter.xcframework)"'
swift package --disable-sandbox --package-path macos/typst_flutter dump-package | grep -E '"name" : "(typst_flutter|typst-flutter|typst_flutter_binary|Binaries/typst_flutter.xcframework)"'
```

Expected: five matching lines per package (package name, product, target, binary target, binary path), no error output. `dump-package` does not require the xcframework to exist yet.

- [ ] **Step 6: Verify the binary target is mandatory, not optional**

Run: `swift build --disable-sandbox --package-path macos/typst_flutter 2>&1 | tail -5`
Expected: the build stops with a message naming `Binaries/typst_flutter.xcframework` (target not found) — that is the loud failure a consumer sees if they skipped setup. Do **not** fix it by relaxing the manifest. Then run `dart run typst_flutter:setup --local` and repeat: the binary target resolves (the build may then fail on the missing `FlutterFramework` dependency path, which is expected outside an app build).

- [ ] **Step 7: Commit**

```bash
git add ios/typst_flutter macos/typst_flutter .gitignore .pubignore
git commit -m "feat(apple): add SwiftPM packages for iOS and macOS"
```

---

### Task 3: Load the process image on Darwin and delete the CocoaPods integration

**Files:**
- Modify: `lib/src/bridge/bridge_io.dart`
- Delete: `ios/typst_flutter.podspec`, `macos/typst_flutter.podspec`, `ios/Classes/typst_flutter.c`, `macos/Classes/typst_flutter.c` (and the now-empty `ios/Classes`, `macos/Classes` directories)
- Test: `test/src/bridge/bridge_io_test.dart` (new)

**Interfaces:**
- Consumes: the packages from Task 2 (they make the Rust symbols part of the app binary).
- Produces: `bool usesProcessLibrary(TargetPlatform platform)` in `lib/src/bridge/bridge_io.dart`, used by `initWithOptionalWebModule`.

- [ ] **Step 1: Write the failing test**

`test/src/bridge/bridge_io_test.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/src/bridge/bridge_io.dart';

void main() {
  test('Apple platforms load symbols from the process image', () {
    expect(usesProcessLibrary(TargetPlatform.iOS), isTrue);
    expect(usesProcessLibrary(TargetPlatform.macOS), isTrue);
  });

  test('other platforms keep flutter_rust_bridge\'s file loader', () {
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      expect(usesProcessLibrary(platform), isFalse, reason: '$platform');
    }
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/src/bridge/bridge_io_test.dart`
Expected: FAIL — `usesProcessLibrary` isn't defined.

- [ ] **Step 3: Implement the loader change**

`lib/src/bridge/bridge_io.dart` becomes:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:typst_flutter/src/rust/frb_generated.dart';

/// Whether this package's Rust symbols are linked into the process image
/// rather than sitting in a library file flutter_rust_bridge can open.
///
/// True on iOS and macOS, where the SwiftPM binary target is a static
/// xcframework and nothing named `libtypst_flutter.dylib` exists in the app.
bool usesProcessLibrary(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

/// Initialises the native bridge, loading the WebAssembly bundle on web.
Future<void> initWithOptionalWebModule({String? webModuleRoot}) =>
    RustLib.init(
      externalLibrary: usesProcessLibrary(defaultTargetPlatform)
          ? ExternalLibrary.process(iKnowHowToUseIt: true)
          : null,
    );
```

If `package:flutter_rust_bridge/flutter_rust_bridge.dart` does not export `ExternalLibrary`, import `package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart` instead — keep the import inside this file so `bridge_web.dart` is untouched.

- [ ] **Step 4: Run the loader test and the whole host suite**

Run: `flutter test test/src/bridge/bridge_io_test.dart test/platform_imports_test.dart`
Expected: PASS (the platform-imports rule still holds: no `dart:io` here).

Run: `flutter test`
Expected: PASS — the mocked-bridge suites never reach `ExternalLibrary.process`.

- [ ] **Step 5: Delete the CocoaPods integration**

```bash
git rm ios/typst_flutter.podspec macos/typst_flutter.podspec
git rm ios/Classes/typst_flutter.c macos/Classes/typst_flutter.c
```

Confirm nothing else references them: `grep -rn "podspec\|Classes/typst_flutter" --include=*.dart --include=*.md --include=*.yml . | grep -v docs/node_modules` — expect only `CHANGELOG.md` history, which Task 9 handles.

- [ ] **Step 6: EXTERNAL — prove the macOS app builds, links and runs**

Human runs, outside the sandbox, from the repo root:

```bash
just build-host                       # universal .a + setup --local (Task 5 adds the chain; until then run `cargo build --release` then `dart run typst_flutter:setup --local`)
cd example && flutter clean && flutter pub get && flutter build macos --release
nm -g build/macos/Build/Products/Release/typst_flutter_example.app/Contents/MacOS/typst_flutter_example | grep -c '_frb_'
flutter test integration_test/simple_test.dart -d macos
```

Expected: build succeeds with no "CocoaPods" line in the log; `nm` prints a count greater than zero; the integration test passes. Paste the `nm` count and the last 20 lines of the test run.

- [ ] **Step 7: Commit**

```bash
git add lib/src/bridge/bridge_io.dart test/src/bridge/bridge_io_test.dart
git commit -m "feat(apple): load the Rust symbols from the process image on Darwin"
```

---

### Task 4: Delete `rust_builder/` and the Android Cargokit fallback

**Files:**
- Delete: `rust_builder/` (whole directory)
- Modify: `android/build.gradle:112-136`
- Modify: `justfile` (`get` recipe: drop the `rust_builder` line)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks; this unblocks the "no CocoaPods, no Cargokit" global constraint.

- [ ] **Step 1: Replace the fallback block in `android/build.gradle`**

Replace the whole `if (!usePrebuilt) { … }` block with:

```gradle
if (!usePrebuilt) {
    throw new GradleException(
        'typst_flutter: pre-built native libraries are missing.\n'
        + 'Run once from your app root, then rebuild:\n'
        + '    dart run typst_flutter:setup'
    )
}
```

Keep the `logger.lifecycle` banner above it if it still reads correctly, or fold the two messages into the exception — the requirement is a single actionable message and no reference to Cargokit.

- [ ] **Step 2: Delete the package**

```bash
git rm -r rust_builder
```

- [ ] **Step 3: Drop it from the justfile's `get` recipe**

Remove the `cd rust_builder {{ and }} flutter pub get` line from `get`; leave `fmt`, `fix`, `clean` and everything else alone.

- [ ] **Step 4: Verify no references remain**

```bash
grep -rn "cargokit\|rust_builder\|rust_lib_typst_flutter" --include=*.gradle --include=*.dart --include=*.yaml --include=*.yml --include=*.md --include=justfile . | grep -v docs/node_modules | grep -v CHANGELOG.md
```

Expected: no output except `CHANGELOG.md` history (excluded above) and, if any, the docs sweep in Task 9.

- [ ] **Step 5: Verify the Android build still configures**

Run: `just get && cd example && flutter build apk --debug`
Expected: PASS — a Gradle configuration and compile pass using the prebuilt `.so`s already in `.typst_flutter_prebuilt/android/`, with no Gradle script error about Cargokit.
If the sandbox blocks Gradle or the SDK download, stop and mark this step EXTERNAL for the human, with the same command; do not guess at the result.

- [ ] **Step 6: Commit**

```bash
git add -A android/build.gradle justfile rust_builder
git commit -m "chore(android): drop the Cargokit fallback and the rust_builder package"
```

---

### Task 5: Justfile recipes for setup and local Apple builds

**Files:**
- Modify: `justfile`

**Interfaces:**
- Consumes: Task 1's `setup --local`, Task 3's build flow.
- Produces: recipes `setup`, `setup-local`, `build-host` (macOS now universal + chained `setup --local`), `build-ios-local` — CI (Task 8) calls `just build-host` and `just build-ios-local`.

- [ ] **Step 1: Add the setup recipes**

```make
# Download the pre-built native libraries into this package
setup:
    dart run typst_flutter:setup

# Install libraries built on this machine (host platform, and macOS xcframework)
setup-local:
    dart run typst_flutter:setup --local

# Build the iOS xcframework from source into the iOS SwiftPM package
build-ios-local:
    rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
    (cd rust && cargo build --release --target aarch64-apple-ios)
    (cd rust && cargo build --release --target aarch64-apple-ios-sim)
    (cd rust && cargo build --release --target x86_64-apple-ios)
    lipo -create rust/target/aarch64-apple-ios-sim/release/libtypst_flutter.a rust/target/x86_64-apple-ios/release/libtypst_flutter.a -output rust/target/libtypst_flutter_sim_fat.a
    rm -rf ios/typst_flutter/Binaries/typst_flutter.xcframework
    mkdir -p ios/typst_flutter/Binaries
    xcodebuild -create-xcframework -library rust/target/aarch64-apple-ios/release/libtypst_flutter.a -library rust/target/libtypst_flutter_sim_fat.a -output ios/typst_flutter/Binaries/typst_flutter.xcframework
```

- [ ] **Step 2: Make the macOS branch of `build-host` universal and chain setup**

Replace the macOS arm of `build-host` so it runs:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin && \
(cd rust && cargo build --release --target aarch64-apple-darwin) && \
(cd rust && cargo build --release --target x86_64-apple-darwin) && \
mkdir -p .typst_flutter_prebuilt/macos && \
lipo -create rust/target/aarch64-apple-darwin/release/libtypst_flutter.a rust/target/x86_64-apple-darwin/release/libtypst_flutter.a -output .typst_flutter_prebuilt/macos/libtypst_flutter.a && \
dart run typst_flutter:setup --local
```

Keep the Windows and Linux arms exactly as they are.

- [ ] **Step 3: Verify the recipes exist and parse**

Run: `just --list`
Expected: `setup`, `setup-local`, `build-ios-local` listed; no parse error.

- [ ] **Step 4: Build the iOS xcframework for real**

Run: `just build-ios-local` (this is slow — the Rust crate builds three times with fat LTO)
Expected: `ios/typst_flutter/Binaries/typst_flutter.xcframework` contains `ios-arm64` and `ios-arm64_x86_64-simulator` slices.

- [ ] **Step 5: Build the host library and check it is universal**

Run: `just build-host && lipo -info .typst_flutter_prebuilt/macos/libtypst_flutter.a`
Expected: `Non-fat file`/`Architectures in the fat file: x86_64 arm64` — specifically it must print **both** `x86_64` and `arm64`. Then `lipo -info macos/typst_flutter/Binaries/typst_flutter.xcframework/macos-arm64_x86_64/libtypst_flutter.a` (or the single-slice directory the wrapper produced) must report both arches too.

- [ ] **Step 6: Commit**

```bash
git add justfile
git commit -m "build: setup and local Apple build recipes"
```

---

### Task 6: Raise the Flutter and Dart floors, bump the version

**Files:**
- Modify: `pubspec.yaml:20-25` (environment), `pubspec.yaml:4` (version)
- Modify: `example/pubspec.yaml` (`environment.sdk`)
- Modify: `CHANGELOG.md` (new top entry)

**Interfaces:**
- Consumes: nothing.
- Produces: `version: 3.2.0`, `flutter: ">=3.44.0"`, `sdk: ^3.12.0` — the release the CI iOS job and the setup downloader assume.

- [ ] **Step 1: Bump the constraints**

`pubspec.yaml`: `version: 3.2.0`, `sdk: ^3.12.0`, `flutter: ">=3.44.0"`.
`example/pubspec.yaml`: `sdk: ^3.12.0`.

- [ ] **Step 2: Add the changelog entry**

```markdown
## 3.2.0

- **Breaking:** iOS and macOS are integrated through Swift Package Manager
  only. The CocoaPods podspecs, the `rust_builder` package and Cargokit are
  gone. Requires Flutter 3.44+ (SwiftPM on by default).
- The native libraries are installed inside `ios/typst_flutter/Binaries/` and
  `macos/typst_flutter/Binaries/`; `dart run typst_flutter:setup` must be run
  after `flutter pub get` and after any dependency change.
- `just build-host` now builds a universal macOS library; `just build-ios-local`
  builds the iOS xcframework from source.
```

- [ ] **Step 3: Verify resolution and analysis**

Run: `flutter pub get && flutter analyze`
Expected: PASS with no dependency-solver error (an internal dependency requiring Flutter < 3.44 would fail here).

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml example/pubspec.yaml CHANGELOG.md pubspec.lock
git commit -m "chore: require Flutter 3.44 and release 3.2.0"
```

---

### Task 7: Migrate `example/ios` to SwiftPM

**Files:**
- Modify: `example/ios/Runner.xcodeproj/project.pbxproj`, `example/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`, `example/ios/Flutter/*.xcconfig` (whatever `flutter build ios` rewrites)
- Ensure absent: `example/ios/Podfile`, `example/ios/Podfile.lock`, `example/ios/Pods/`

**Interfaces:**
- Consumes: Tasks 1–6 (packages, binary install, recipes, floors).
- Produces: a committed SPM-migrated example project.

- [ ] **Step 1: Confirm the starting state**

Run: `grep -c "FlutterGeneratedPluginSwiftPackage" example/ios/Runner.xcodeproj/project.pbxproj; ls example/ios/Podfile 2>/dev/null`
Expected: `0` and no Podfile — the project is still CocoaPods-shaped.

- [ ] **Step 2: EXTERNAL — let Flutter migrate the project**

Human runs outside the sandbox:

```bash
cd example && flutter clean && flutter pub get && flutter build ios --no-codesign
```

Expected: build succeeds, and Flutter reports adding Swift Package Manager integration (no "CocoaPods" install step). Paste the last 20 lines.

- [ ] **Step 3: Verify the migration landed where the review expects**

```bash
grep -c "FlutterGeneratedPluginSwiftPackage" example/ios/Runner.xcodeproj/project.pbxproj
grep -rn "Pods-Runner" example/ios/Flutter/*.xcconfig || echo "no Pods xcconfig references"
ls example/ios/Podfile 2>/dev/null || echo "no Podfile"
```

Expected: a non-zero package reference count, no `Pods-Runner` includes, no Podfile.

- [ ] **Step 4: EXTERNAL — run the simulator integration test**

```bash
cd example && flutter test integration_test/simple_test.dart -d "iPhone 16 Pro"
```

Expected: PASS (compile to PDF on the simulator). This is the only check that exercises the iOS slice of the xcframework end to end.

- [ ] **Step 5: Commit the generated project changes**

```bash
git add example/ios
git commit -m "test(example): migrate the iOS Runner project to SwiftPM"
```

---

### Task 8: CI builds iOS, and the macOS example job uses the new recipes

**Files:**
- Modify: `.github/workflows/ci.yml` (new `ios-build` job)
- Modify: `.github/workflows/build-windows-example.yml:207-235` (macOS job's Rust step)

**Interfaces:**
- Consumes: `just build-host`, `just build-ios-local` from Task 5.
- Produces: CI coverage for the new wiring.

- [ ] **Step 1: Add the iOS job to `ci.yml`**

```yaml
  ios-build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
        with:
          channel: "stable"
          cache: true
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-apple-ios,aarch64-apple-ios-sim,x86_64-apple-ios
      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: rust
      - uses: taiki-e/install-action@just
      - name: Install dependencies
        run: just get
      - name: Build the iOS xcframework
        run: just build-ios-local
      - name: Build the example for the simulator
        run: cd example && flutter build ios --simulator
```

- [ ] **Step 2: Point the macOS example job at `build-host`**

In `build-windows-example.yml`, replace the job's "Build Rust Libraries (Universal)" step body with `just build-host` (the recipe now does the two-target build, the `lipo`, and `dart run typst_flutter:setup --local`), after adding `taiki-e/install-action@just` to that job's steps if it isn't already there.

- [ ] **Step 3: Verify the workflow syntax**

Run: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/ci.yml','.github/workflows/build-windows-example.yml']]; print('yaml ok')"`
Expected: `yaml ok`. If `actionlint` is available, run it too and expect no findings.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/build-windows-example.yml
git commit -m "ci: build the example for iOS and use the new macOS recipe"
```

---

### Task 9: Documentation sweep

**Files:**
- Modify: `README.md`
- Modify: `docs/src/content/docs/guides/getting-started.md`
- Modify: `GEMINI.md`
- Modify: `RELEASE_PROCESS.md`
- Modify: `todo.md`
- Modify: `CHANGELOG.md` (only if a fact changed after Task 6)

**Interfaces:**
- Consumes: every earlier task's behavior as written; the doc must describe what the code does, not what was hoped for.
- Produces: nothing code-facing.

- [ ] **Step 1: Rewrite the README install section**

Replace the "Tip" about Gradle/CocoaPods/CMake auto-download with the truth: only Gradle auto-runs setup; on iOS/macOS setup must run first, and it must be re-run after `flutter pub get`, `pub upgrade`, `pub cache clean`/`repair`, or a change of git ref (a git dependency resolves to a new pub-cache directory). Delete the "Advanced Fallback (Cargokit)" section and replace it with a short "Building the native library yourself" section pointing at `just build-host` / `just build-ios-local` plus `dart run typst_flutter:setup --local`.

- [ ] **Step 2: Update `docs/src/content/docs/guides/getting-started.md`**

Same corrections in the getting-started prose (lines ~18-45): setup is required before the first Apple build, the auto-download only happens in Gradle, and the SwiftPM packages are described in one paragraph.

- [ ] **Step 3: Update `GEMINI.md`**

Replace the "Automated Native Builds with Cargokit" paragraph with a description of the SwiftPM layout (`ios/typst_flutter/`, `macos/typst_flutter/`, `Binaries/`), the `-Wl,-u,_frb_get_rust_content_hash` anchor, and the `ExternalLibrary.process()` loader. Fix the table entry that lists `build-ios` outputs if it names a bare `.a`.

- [ ] **Step 4: Update `RELEASE_PROCESS.md` and `todo.md`**

`RELEASE_PROCESS.md`: state that the iOS xcframework asset is unchanged, that no macOS xcframework asset is published (setup wraps the `.a`), and that consumers must re-run setup after a version bump.
`todo.md`: tick off the SPM migration (it is not listed — add it under the completed section with the design-doc link), and adjust the "Dart & Flutter Native Assets" item so it no longer claims Cargokit is the current mechanism.

- [ ] **Step 5: Verify no stale instructions remain**

```bash
grep -rn "pod install\|CocoaPods\|Cargokit\|rust_builder" README.md GEMINI.md RELEASE_PROCESS.md todo.md docs/src/content --include=*.md --include=*.mdx | grep -v "no longer\|removed\|replaced"
```

Expected: no output (mentions of the old world are only allowed where the sentence says it was removed).

- [ ] **Step 6: Commit**

```bash
git add README.md GEMINI.md RELEASE_PROCESS.md todo.md docs/src/content
git commit -m "docs: describe Swift Package Manager instead of CocoaPods"
```

---

## Final verification (after all tasks)

- [ ] `flutter analyze && flutter test` pass.
- [ ] `just build-ios-local` then EXTERNAL `cd example && flutter build ios --no-codesign` and the simulator integration test pass.
- [ ] EXTERNAL `cd example && flutter build macos --release`, `nm -g …/typst_flutter_example | grep _frb_` is non-empty, and the macOS integration test passes.
- [ ] `cd example && flutter build apk --debug` passes (Android untouched apart from the Gradle message).
- [ ] `grep -rn "podspec\|Podfile\|cargokit" --include=*.dart --include=*.gradle --include=*.yml --include=justfile .` (minus `docs/node_modules`, `example/build`, `CHANGELOG.md`) returns nothing.
- [ ] On a machine with CocoaPods uninstalled, `flutter build macos` still works — the check that nothing depends on it.
