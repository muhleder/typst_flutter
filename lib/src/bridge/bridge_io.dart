import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
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
